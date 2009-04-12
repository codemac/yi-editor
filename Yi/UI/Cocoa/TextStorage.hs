{-# LANGUAGE TemplateHaskell, EmptyDataDecls, MultiParamTypeClasses,
             FlexibleInstances, TypeSynonymInstances,
             DeriveDataTypeable, Rank2Types #-}
--
-- Copyright (c) 2008 Gustav Munkby
--

-- | An implementation of NSTextStorage that uses Yi's FBuffer as
-- the backing store.

module Yi.UI.Cocoa.TextStorage
  ( TextStorage
  , initializeClass_TextStorage
  , newTextStorage
  , setTextStorageBuffer
  , visibleRangeChanged
  ) where

import Prelude (takeWhile, take, dropWhile, drop, span, unzip)
import Yi.Editor (currentRegex, emptyEditor, Editor)
import Yi.Prelude
import Yi.Buffer
import Yi.Style
import Yi.Syntax
import Yi.UI.Cocoa.Utils
import Yi.UI.Utils
import Yi.Window

import Data.Maybe
import qualified Data.Rope as R
import qualified Data.Map as M
import qualified Data.List as L

import Foreign hiding (new)
import Foreign.C

-- Specify Cocoa imports explicitly, to avoid name-clashes.
-- Since the number of functions recognized by HOC varies
-- between revisions, this seems like the safest choice.
import HOC
import Foundation (
  Unichar,NSString,NSStringClass,NSDictionary,NSRange(..),NSRangePointer,
  NSStringMetaClass,
  length,attributeAtIndexEffectiveRange,attributesAtIndexEffectiveRange,
  attributesAtIndexLongestEffectiveRangeInRange,nsMaxRange,
  beginEditing,endEditing,setAttributesRange,haskellString,
  substringWithRange,initWithStringAttributes,alloc,
  addAttributeValueRange,addAttributesRange)
import AppKit (
  NSTextStorage,NSTextStorageClass,string,fixesAttributesLazily,
  NSTextStorageMetaClass,
  _NSCursor,_NSFont,replaceCharactersInRangeWithString,
  _NSParagraphStyle,defaultParagraphStyle,ibeamCursor,_NSTextStorage,
  editedRangeChangeInLength,nsTextStorageEditedAttributes,
  nsTextStorageEditedCharacters,userFixedPitchFontOfSize)

-- Unfortunately, my version of hoc does not handle typedefs correctly,
-- and thus misses every selector that uses the "unichar" type, even
-- though it has introduced a type alias for it...
$(declareRenamedSelector "characterAtIndex:" "characterAtIndex" [t| CUInt -> IO Unichar |])
instance Has_characterAtIndex (NSString a)
$(declareRenamedSelector "getCharacters:range:" "getCharactersRange" [t| Ptr Unichar -> NSRange -> IO () |])
instance Has_getCharactersRange (NSString a)


-- | SplitRope provides means for tracking the position
--   of Cocoa reads from the underlying rope...
data SplitRope = SplitRope
  R.Rope -- Cocoa has moved beyond this portion
  R.Rope -- Cocoa is currently accessing this part
  [Unichar] -- But in this format... =)

-- | Create a new SplitRope, and initialize the encoded portion appropriately.
mkSplitRope :: R.Rope -> R.Rope -> SplitRope
mkSplitRope done next =
  SplitRope done next (concatMap (encodeUTF16 . fromEnum) (R.toString next))

-- | Get the length of the whole SplitRope.
sLength :: SplitRope -> Int
sLength (SplitRope done next _) = R.length done + R.length next

-- | Ensure that the specified position is in the first chunk of
--   the ``next'' rope.
sSplitAtChunkBefore :: Int -> SplitRope -> SplitRope
sSplitAtChunkBefore n s@(SplitRope done next _)
  | n < R.length done = mkSplitRope done' (R.append renext next)
  | R.null redone     = s
  | otherwise         = mkSplitRope (R.append done redone) next'
  where
    (done', renext) = R.splitAtChunkBefore n done
    (redone, next') = R.splitAtChunkBefore (n - R.length done) next

sStringAt :: Int -> SplitRope -> [Unichar]
sStringAt n (SplitRope done _ cs) = L.drop (n - R.length done) cs

encodeUTF16 :: Int -> [Unichar]
encodeUTF16 c
  | c < 0x10000 = [fromIntegral c]
  | otherwise   = let c' = c - 0x10000
                  in [0xd800 .|. (fromIntegral $ c' `shiftR` 10),
                      0xdc00 .|. (fromIntegral $ c' .&. 0x3ff)]

-- Introduce a NSString subclass that has a Data.Rope internally.
-- A NSString subclass needs to implement length and characterAtIndex,
-- and for performance reasons getCharactersRange.
-- This implementation is a hack just like the old bytestring one,
-- but less so as Rope uses character indices instead of byte indices.
-- In theory, this should work fine for all characters in the
-- unicode BMP. I am unsure as to what happens if any characters
-- outside of the BMP are used.
$(declareClass "YiRope" "NSString")
$(exportClass "YiRope" "yirope_" [
    InstanceVariable "str" [t| SplitRope |] [| mkSplitRope R.empty R.empty |]
  , InstanceMethod 'length -- '
  , InstanceMethod 'characterAtIndex -- '
  , InstanceMethod 'getCharactersRange -- '
  ])

yirope_length :: YiRope () -> IO CUInt
yirope_length slf = do
  -- logPutStrLn $ "Calling yirope_length (gah...)"
  slf #. _str >>= return . fromIntegral . sLength

yirope_characterAtIndex :: CUInt -> YiRope () -> IO Unichar
yirope_characterAtIndex i slf = do
  -- logPutStrLn $ "Calling yirope_characterAtIndex " ++ show i
  flip (modifyIVar _str) slf $ \s -> do
    s' <- return (sSplitAtChunkBefore (fromIntegral i) s)
    return (s', head (sStringAt (fromIntegral i) s'))

yirope_getCharactersRange :: Ptr Unichar -> NSRange -> YiRope () -> IO ()
yirope_getCharactersRange p _r@(NSRange i l) slf = do
  -- logPutStrLn $ "Calling yirope_getCharactersRange " ++ show r
  flip (modifyIVar_ _str) slf $ \s -> do
    s' <- return (sSplitAtChunkBefore (fromIntegral i) s)
    pokeArray p (L.take (fromIntegral l) (sStringAt (fromIntegral i) s'))
    return s'

-- An implementation of NSTextStorage that uses Yi's FBuffer as
-- the backing store. An implementation must at least implement
-- a O(1) string method and attributesAtIndexEffectiveRange.
-- For performance reasons, attributeAtIndexEffectiveRange is
-- implemented to deal with specific properties such as font.

-- Judging by usage logs, the environment using the text storage
-- seem to rely on strings O(1) behavior and thus caching the
-- result seems like a good idea. In addition attributes are
-- queried for the same location multiple times, and thus caching
-- them as well also seems fruitful.

-- | Use this as the base length of computed stroke ranges
strokeRangeExtent :: Num t => t
strokeRangeExtent = 4000

type PicStroke = (Point, Attributes)
data Picture = Picture
  { picRegion :: Region
  , picStrokes :: [PicStroke]
  }

instance Show Picture where
  show (Picture r ss) = "{{"++show r ++": "++show (take 1 ss)++"@"++show (L.length ss)++"}}"

emptyPicture :: (Picture, NSRange)
emptyPicture = (Picture emptyRegion [], NSRange 0 0)

nullPicture :: Picture -> Bool
nullPicture = null . picStrokes -- Or empty region??

regionEnds :: Region -> (Point, Point)
regionEnds r = (regionStart r, regionEnd r)

dropStrokesWhile :: (PicStroke -> Bool) -> Picture -> Picture
dropStrokesWhile f pic = pic { picRegion = mkRegion nb pe, picStrokes = strokes }
  where 
    (pb, pe) = regionEnds $ picRegion pic
    (nb, strokes) = helper pb (picStrokes pic)
    helper :: Point -> [PicStroke] -> (Point, [PicStroke])
    helper p [] = (p,[])
    helper p ~(x:xs)
      | f x       = helper (fst x) xs
      | otherwise = (p, x:xs)

-- | Extend the currently cached picture, so that it at least
--   covers the desired region. The resulting picture starts
--   at the location of the desired region, but might extend
--   further...
extendPicture :: Region -> (Region -> IO Picture) -> Picture -> IO Picture
extendPicture desired ext cache = do
  -- All possible overlappings of desired and cache regions:
  -- dd   dd  ddd  ddd dddd dd  dd ddd  dd   dd  dd  ddd   dd <- desired
  --   cc  cc  ccc  cc  cc  ccc cc cc  cccc ccc cc  ccc  cc   <- cache
  --  A    B    E   B    A   N  N   E   N    N   A   E    A   <- Get All/Begin/End/None
  -- logPutStrLn $ "extendPicture " ++ show ((db `inRegion` (picRegion cache)), ((de `compare` cb) /= (de `compare` ce)))
  case (
    db `inRegion` (picRegion cache), -- Have start
    de `compare` cb /= de `compare` ce     -- Have end
    ) of 
    ( True,  True) -> return $ dropJunk cache
    ( True, False) -> append (dropJunk cache) <$> ext (mkExtentRegion ce de)
    (False,  True) -> flip append cache       <$> ext (mkRegion db cb)
    (False, False) -> ext (mkExtentRegion db de)
  -- ext (mkExtentRegion db de)
  where
    (db, de) = regionEnds desired
    (cb, ce) = regionEnds $ picRegion cache
    mkExtentRegion b e = mkSizeRegion b (max (b ~- e) strokeRangeExtent)
    dropJunk p = Picture -- Like dropStrokesWhile but always use db as starting point
      { picRegion = mkRegion db (regionEnd $ picRegion p) 
      , picStrokes = dropWhile ((db >=) . fst) (picStrokes p) 
      }
    append p1 p2 = Picture
      { picRegion = mkRegion (regionStart $ picRegion p1) (regionEnd $ picRegion p2)
      , picStrokes = picStrokes p1 ++ picStrokes p2
      }

type YiState = (Editor, FBuffer, Window, UIStyle, YiRope ())

$(declareClass "YiTextStorage" "NSTextStorage")
$(exportClass "YiTextStorage" "yts_" [
    InstanceVariable "yiState" [t| YiState |] [| error "Uninitialized" |]
  , InstanceVariable "dictionaryCache" [t| M.Map Attributes (NSDictionary ()) |] [| M.empty |]
  , InstanceVariable "pictureCache" [t| (Picture, NSRange) |] [| emptyPicture |]
  , InstanceMethod 'string -- '
  , InstanceMethod 'fixesAttributesLazily -- '
  , InstanceMethod 'attributeAtIndexEffectiveRange -- '
  , InstanceMethod 'attributesAtIndexEffectiveRange -- '
  , InstanceMethod 'attributesAtIndexLongestEffectiveRangeInRange
  , InstanceMethod 'replaceCharactersInRangeWithString -- '
  , InstanceMethod 'setAttributesRange     -- Disallow changing attributes
  , InstanceMethod 'addAttributesRange     -- optimized to avoid needless work
  , InstanceMethod 'addAttributeValueRange -- ...
  , InstanceMethod 'length -- '
  ])

_editor :: YiTextStorage () -> IO Editor
_buffer :: YiTextStorage () -> IO FBuffer
_window :: YiTextStorage () -> IO Window
_uiStyle :: YiTextStorage () -> IO UIStyle
_stringCache :: YiTextStorage () -> IO (YiRope ())
_editor      o = (\ (x,_,_,_,_) -> x) <$>  o #. _yiState
_buffer      o = (\ (_,x,_,_,_) -> x) <$>  o #. _yiState
_window      o = (\ (_,_,x,_,_) -> x) <$>  o #. _yiState
_uiStyle     o = (\ (_,_,_,x,_) -> x) <$>  o #. _yiState
_stringCache o = (\ (_,_,_,_,x) -> x) <$>  o #. _yiState

yts_length :: YiTextStorage () -> IO CUInt
yts_length slf = do
  -- logPutStrLn "Calling yts_length "
  slf # _stringCache >>= length

yts_string :: YiTextStorage () -> IO (NSString ())
yts_string slf = castObject <$> slf # _stringCache

yts_fixesAttributesLazily :: YiTextStorage () -> IO Bool
yts_fixesAttributesLazily _ = return True

yts_attributesAtIndexEffectiveRange :: CUInt -> NSRangePointer -> YiTextStorage () -> IO (NSDictionary ())
yts_attributesAtIndexEffectiveRange i er slf = do
  (cache, _) <- slf #. _pictureCache
  if (fromIntegral i `inRegion` picRegion cache)
    then returnEffectiveRange cache i er (mkRegionRange $ picRegion cache) slf
    else yts_attributesAtIndexLongestEffectiveRangeInRange i er (NSRange i 1) slf

yts_attributesAtIndexLongestEffectiveRangeInRange :: CUInt -> NSRangePointer -> NSRange -> YiTextStorage () -> IO (NSDictionary ())
yts_attributesAtIndexLongestEffectiveRangeInRange i er rl slf = do
  (cache, prev_rl) <- slf #. _pictureCache
  -- Since we only cache the remaining part of the rl window, we must
  -- check to ensure that we do not re-read the window all the time...
  let use_rl = if prev_rl == rl then NSRange i (nsMaxRange rl) else rl
  -- logPutStrLn $ "yts_attributesAtIndexLongestEffectiveRangeInRange " ++ show i ++ " " ++ show rl
  full <- extendPicture (mkRangeRegion use_rl) (flip storagePicture slf) cache
  -- TODO: Only merge identical strokes when "needed"?
  returnEffectiveRange full i er rl slf

returnEffectiveRange :: Picture -> CUInt -> NSRangePointer -> NSRange -> YiTextStorage () -> IO (NSDictionary ())
returnEffectiveRange full i er rl slf = do
  pic <- return $ dropStrokesWhile ((fromIntegral i >=) . fst) full
  -- logPutStrLn $ "returnEffectiveRange " ++ show pic
  slf # setIVar _pictureCache (pic, rl)
  if nullPicture pic
    then error "Empty picture?"
    else do
      let begin = fromIntegral $ regionStart $ picRegion pic
      let (next,s) = head $ picStrokes pic
      let end = min (fromIntegral next) (nsMaxRange rl)
      len <- yts_length slf
      safePoke er (NSRange begin ((min end len) - begin))
      -- Keep a cache of seen styles... usually, there should not be to many
      -- TODO: Have one centralized cache instead of one per text storage...
      dict <- slf # cachedDictionaryFor s
      -- TODO: Introduce some sort of cache for this...
      -- Create a new NSTextStorage to enforce Cocoa font-substitution
      str <- yts_string slf >>= substringWithRange (NSRange begin ((min end len) - begin))
      store <- _NSTextStorage # alloc >>= initWithStringAttributes str dict
      -- Extract the dictionary with adjusted fonts, and new (smaller) range
      dict2 <- store # attributesAtIndexEffectiveRange (i - begin) er
      when (er /= nullPtr) $ do
        -- If we got a range, we should offset it Offset the effective range accordingly
        NSRange b2 l2 <- peek er
        poke er (NSRange (begin + b2) l2)
      return dict2

cachedDictionaryFor :: Attributes -> YiTextStorage () -> IO (NSDictionary ())
cachedDictionaryFor s slf = do
  slf # modifyIVar _dictionaryCache (\dicts ->
    case M.lookup s dicts of
      Just dict -> return (dicts, dict)
      _ -> do
        dict <- convertAttributes s
        return (M.insert s dict dicts, dict))

  

yts_attributeAtIndexEffectiveRange :: forall t. NSString t -> CUInt -> NSRangePointer -> YiTextStorage () -> IO (ID ())
yts_attributeAtIndexEffectiveRange attr i er slf = do
  attr' <- haskellString attr
  case attr' of
    "NSFont" -> do
      safePokeFullRange >> castObject <$> userFixedPitchFontOfSize 0 _NSFont
    "NSGlyphInfo" -> do
      safePokeFullRange >> return nil
    "NSAttachment" -> do
      safePokeFullRange >> return nil
    "NSCursor" -> do
      safePokeFullRange >> castObject <$> ibeamCursor _NSCursor
    "NSToolTip" -> do
      safePokeFullRange >> return nil
    "NSLanguage" -> do
      safePokeFullRange >> return nil
    "NSLink" -> do
      safePokeFullRange >> return nil
    "NSParagraphStyle" -> do
      -- TODO: Adjust line break property...
      safePokeFullRange >> castObject <$> defaultParagraphStyle _NSParagraphStyle
    "NSBackgroundColor" -> do
      -- safePokeFullRange >> castObject <$> blackColor _NSColor
      len <- yts_length slf
      ~((s,a):_) <- onlyBg <$> picStrokes <$> slf # storagePicture (mkSizeRegion (fromIntegral i) strokeRangeExtent)
      safePoke er (NSRange i ((min len (fromIntegral s)) - i))
      castObject <$> getColor False (background a)
    _ -> do
      -- TODO: Optimize the other queries as well (if needed)
      -- logPutStrLn $ "Unoptimized yts_attributeAtIndexEffectiveRange " ++ attr' ++ " at " ++ show i
      super slf # attributeAtIndexEffectiveRange attr i er
  where
    safePokeFullRange = do
      b <- slf # _buffer
      safePoke er (NSRange 0 (fromIntegral $ runBufferDummyWindow b sizeB))

-- These methods are used to modify the contents of the NSTextStorage.
-- We do not allow direct updates of the contents this way, though.
yts_replaceCharactersInRangeWithString :: forall t. NSRange -> NSString t -> YiTextStorage () -> IO ()
yts_replaceCharactersInRangeWithString _ _ _ = return ()
yts_setAttributesRange :: forall t. NSDictionary t -> NSRange -> YiTextStorage () -> IO ()
yts_setAttributesRange _ _ _ = return ()
yts_addAttributesRange :: NSDictionary t -> NSRange -> YiTextStorage () -> IO ()
yts_addAttributesRange _ _ _ = return ()
yts_addAttributeValueRange :: NSString t -> ID () -> NSRange -> YiTextStorage () -> IO ()
yts_addAttributeValueRange _ _ _ _ = return ()

-- | Remove element x_i if f(x_i,x_(i+1)) is true
filter2 :: (a -> a -> Bool) -> [a] -> [a]
filter2 _f [] = []
filter2 _f [x] = [x]
filter2 f (x1:x2:xs) =
  (if f x1 x2 then id else (x1:)) $ filter2 f (x2:xs)

-- | Keep only the background information
onlyBg :: [PicStroke] -> [PicStroke]
onlyBg = filter2 ((==) `on` (background . snd))

-- | Get a picture where each component (p,style) means apply the style
--   up until the given point p.
paintCocoaPicture :: UIStyle -> Point -> [PicStroke] -> [PicStroke]
paintCocoaPicture sty end = tail . stylesift (baseAttributes sty)
  where
    -- Turn a picture of use style from p into a picture of use style until p
    stylesift s [] = [(end,s)]
    stylesift s ((p,t):xs) = (p,s):(stylesift t xs)

-- | A version of poke that does nothing if p is null.
safePoke :: (Storable a) => Ptr a -> a -> IO ()
safePoke p x = when (p /= nullPtr) (poke p x)

-- | Execute strokeRangesB on the buffer, and update the buffer
--   so that we keep around cached syntax information...
--   We assume that the incoming region provide character-indices,
--   and we need to find out the corresponding byte-indices
storagePicture :: Region -> YiTextStorage () -> IO Picture
storagePicture r slf = do
  (ed, buf, win, sty, _) <- slf #. _yiState
  -- logPutStrLn $ "storagePicture " ++ show i
  return $ bufferPicture ed sty buf win r

bufferPicture :: Editor -> UIStyle -> FBuffer -> Window -> Region -> Picture
bufferPicture ed sty buf win r =
  Picture
    { picRegion = r
    , picStrokes =
        paintCocoaPicture sty (regionEnd r) $
          (fst $ runBuffer win buf (attributesPictureB sty (currentRegex ed) r []))
    }
  
type TextStorage = YiTextStorage ()
initializeClass_TextStorage :: IO ()
initializeClass_TextStorage = do
  initializeClass_YiRope
  initializeClass_YiTextStorage

applyUpdate :: YiTextStorage () -> FBuffer -> Update -> IO ()
applyUpdate buf b (Insert p _ s) =
  buf # editedRangeChangeInLength nsTextStorageEditedCharacters
          (NSRange (fromIntegral p) 0) (fromIntegral $ R.length s)

applyUpdate buf b (Delete p _ s) =
  let len = R.length s in
  buf # editedRangeChangeInLength nsTextStorageEditedCharacters
          (NSRange (fromIntegral p) (fromIntegral len)) (fromIntegral (negate len))

newTextStorage :: UIStyle -> FBuffer -> Window -> IO TextStorage
newTextStorage sty b w = do
  buf <- new _YiTextStorage
  s <- new _YiRope
  s # setIVar _str (mkSplitRope R.empty (runBufferDummyWindow b (streamB Forward 0)))
  buf # setIVar _yiState (emptyEditor, b, w, sty, s)
  buf # setMonospaceFont
  return buf

setTextStorageBuffer :: Editor -> FBuffer -> TextStorage -> IO ()
setTextStorageBuffer ed buf storage = do
  storage # beginEditing
  flip (modifyIVar_ _yiState) storage $ \ (_,_,w,sty,s) -> do
    s # setIVar _str (mkSplitRope R.empty (runBufferDummyWindow buf (streamB Forward 0)))
    return (ed, buf, w, sty, s)
  when (not $ null $ getVal pendingUpdatesA buf) $ do
    mapM_ (applyUpdate storage buf) [u | TextUpdate u <- getVal pendingUpdatesA buf]
    storage # setIVar _pictureCache emptyPicture
  storage # endEditing

visibleRangeChanged :: NSRange -> TextStorage -> IO ()
visibleRangeChanged range storage = do
  storage # setIVar _pictureCache emptyPicture
  storage # editedRangeChangeInLength nsTextStorageEditedAttributes range 0
