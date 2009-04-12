{-# LANGUAGE TemplateHaskell, ForeignFunctionInterface, ExistentialQuantification, TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, DeriveDataTypeable #-}
--
-- Copyright (c) 2007, 2008 Jean-Philippe Bernardy
-- Copyright (c) 2008 Gustav Munkby
--

-- | This module defines a user interface implemented using Cocoa.

module Yi.UI.Cocoa (start) where

import Prelude (Float)

import Yi.UI.Cocoa.Application
import Yi.UI.Cocoa.TextStorage
import Yi.UI.Cocoa.TextView
import Yi.UI.Cocoa.Utils

import Yi.Prelude hiding (init)
import Yi.Buffer
import Yi.Editor
import Yi.Keymap
import Yi.Monad
import Yi.Config
import Yi.Rectangle
import Yi.String
import qualified Yi.UI.Common as Common
import qualified Yi.Style as Style
import Yi.Window
import Paths_yi (getDataFileName)

import Control.Monad.Reader (when)

import qualified Data.List as L
import qualified Data.List.PointedList.Circular as PL
import Data.IORef
import Data.Maybe
import Data.Monoid
import Data.Unique

-- Specify Cocoa imports explicitly, to avoid name-clashes.
-- Since the number of functions recognized by HOC varies
-- between revisions, this seems like the safest choice.
import HOC
import Foundation (
  NSPoint(..),NSRect(..),NSRange(..),NSSize(..),nsHeight,nsWidth,
  _NSThread,detachNewThreadSelectorToTargetWithObject,alloc,init,
  NSObject,toNSString,respondsToSelector,_NSMutableArray,array,
  _NSValue,valueWithRange,addObject,NSMutableArray)
import AppKit (
  frame,bounds,setFrame,NSView,_NSView,NSTextField,_NSTextField,
  NSCell,_NSSplitView,_NSImage,NSApplication,sharedApplication,
  terminate_,run,setApplicationIconImage,NSWindow,_NSWindow,_NSMenu,
  activateIgnoringOtherApps,makeKeyAndOrderFront,setMainMenu,
  addSubview,removeFromSuperview,Has_setBackgroundColor,
  Has_setTextColor,NSSplitView,_NSFont,addSubviewPositionedRelativeTo,
  fontWithNameSize,setUserFixedPitchFont,userFixedPitchFontOfSize,
  adjustSubviews,cell,center,containerSize,nsWindowBelow,
  initWithContentRectStyleMaskBackingDefer,initWithContentsOfFile,
  initWithFrame,layoutManager,makeFirstResponder,
  nsBackingStoreBuffered,nsClosableWindowMask,nsLeftTextAlignment,
  nsLineBreakByTruncatingMiddle,nsMiniaturizableWindowMask,
  nsResizableWindowMask,nsTitledWindowMask,nsViewHeightSizable,
  nsViewMaxYMargin,nsViewNotSizable,nsViewWidthSizable,
  performMiniaturize,replaceTextStorage,scrollRangeToVisible,
  setAlignment,setAutodisplay,setAutohidesScrollers,
  setAutoresizingMask,setBackgroundColor,setBezeled,setBordered,
  setContainerSize,setDelegate,setDocumentView,setEditable,
  setFrameAutosaveName,setHasHorizontalScroller,setHasVerticalScroller,
  setHorizontallyResizable,setInsertionPointColor,setLineBreakMode,
  setRichText,setSelectable,setSelectedRanges,NSLayoutManager,
  setSelectedTextAttributes,setStringValue,setTextColor,setTitle,
  setVerticallyResizable,setWidthTracksTextView,setWindowsMenu,
  setWraps,sizeToFit,textColor,textContainer)

import qualified AppKit.NSWindow
import qualified AppKit.NSView

import Foreign.C
import Foreign hiding (new)

foreign import ccall "Processes.h TransformProcessType" transformProcessType :: Ptr (CInt) -> CInt -> IO (CInt)
foreign import ccall "Processes.h SetFrontProcess" setFrontProcess :: Ptr (CInt) -> IO (CInt)
foreign import ccall "Processes.h GetCurrentProcess" getCurrentProcess :: Ptr (CInt) -> IO (CInt)

-- Don't import this, since it is only available in Leopard...
$(declareRenamedSelector "setAllowsNonContiguousLayout:" "setAllowsNonContiguousLayout" [t| Bool -> IO () |])
instance Has_setAllowsNonContiguousLayout (NSLayoutManager a)
_silenceWarning :: ImpType_setAllowsNonContiguousLayout a b
_silenceWarning = undefined

------------------------------------------------------------------------

data UI = UI {uiWindow :: NSWindow ()
             ,uiBox :: NSSplitView ()
             ,uiCmdLine :: NSTextField ()
             ,windowCache :: IORef [WinInfo]
             ,uiActionCh :: Action -> IO ()
             ,uiFullConfig :: Config
             }

uiConfig :: UI -> UIConfig
uiConfig = configUI . uiFullConfig

data WinInfo = WinInfo
  { wikey    :: !Unique        -- ^ Uniquely identify each window
  , window   :: Window         -- ^ The editor window that we reflect
  , textview :: YiTextView ()
  , modeline :: NSTextField ()
  , widget   :: NSView ()      -- ^ Top-level widget for this window.
  , storage  :: TextStorage
  }

mkUI :: UI -> Common.UI
mkUI ui = Common.dummyUI
  { Common.main    = main
  , Common.end     = const end
  , Common.suspend = uiWindow ui # performMiniaturize nil
  , Common.refresh = refresh ui
  }

mkRect :: Float -> Float -> Float -> Float -> NSRect
mkRect x y w h = NSRect (NSPoint x y) (NSSize w h)

allSizable, normalWindowMask :: CUInt
allSizable = nsViewWidthSizable .|. nsViewHeightSizable
normalWindowMask =
  nsTitledWindowMask .|. nsResizableWindowMask .|. nsClosableWindowMask .|. nsMiniaturizableWindowMask

initWithContentRect :: NSRect -> NewlyAllocated (NSWindow ()) -> IO (NSWindow ())
initWithContentRect r =
  initWithContentRectStyleMaskBackingDefer r normalWindowMask nsBackingStoreBuffered True

toNSView :: forall t. ID () -> NSView t
toNSView = castObject

toYiApplication :: forall t1 t2. NSApplication t1 -> YiApplication t2
toYiApplication = castObject
toYiController :: forall t1 t2. NSObject t1 -> YiController t2
toYiController = castObject

newTextLine :: IO (NSTextField ())
newTextLine = do
  tl <- new _NSTextField
  tl # setAlignment nsLeftTextAlignment
  tl # setAutoresizingMask (nsViewWidthSizable .|. nsViewMaxYMargin)
  tl # setMonospaceFont
  tl # setSelectable True
  tl # setEditable False
  tl # setBezeled False
  tl # sizeToFit
  cl <- castObject <$> tl # cell :: IO (NSCell ())
  cl # setWraps False
  cl # setLineBreakMode nsLineBreakByTruncatingMiddle
  return tl

addSubviewWithTextLine :: Maybe (NSView t0) -> NSView t1 -> NSView t2 -> IO (NSTextField (), NSView ())
addSubviewWithTextLine sibling view parent = do
  container <- new _NSView
  parent # bounds >>= flip setFrame container
  container # setAutoresizingMask allSizable
  view # setAutoresizingMask allSizable
  container # addSubview view

  text <- newTextLine
  container # addSubview text
  case sibling of
    Nothing -> parent # addSubview container
    Just v -> parent # addSubviewPositionedRelativeTo container nsWindowBelow v

  -- Adjust frame sizes, as superb cocoa cannot do this itself...
  txtbox <- text # frame
  winbox <- container # bounds
  view # setFrame (mkRect 0 (nsHeight txtbox) (nsWidth winbox) (nsHeight winbox - nsHeight txtbox))
  text # setFrame (mkRect 0 0 (nsWidth winbox) (nsHeight txtbox))

  return (text, container)

-- | Initialise the ui
start :: UIBoot
start cfg ch outCh _ed = do

  -- Ensure that our command line application is also treated as a gui application
  fptr <- mallocForeignPtrBytes 32 -- way to many bytes, but hey...
  withForeignPtr fptr $ getCurrentProcess
  withForeignPtr fptr $ (flip transformProcessType) 1
  withForeignPtr fptr $ setFrontProcess

  -- Publish Objective-C classes...
  initializeClass_Application
  initializeClass_YiTextView
  initializeClass_TextStorage
  initializeClass_YiScrollView

  app <- _YiApplication # sharedApplication >>= return . toYiApplication
  app # setIVar _eventChannel (Just ch)
  app # setIVar _runAction (Just $ outCh . singleton . makeAction)

  -- Multithreading in Cocoa is initialized by spawning a new thread
  -- This spawns a thread that immediately exits, but that's okay
  _NSThread # detachNewThreadSelectorToTargetWithObject
     (getSelectorForName "sharedApplication") _YiApplication nil

  -- Set the application icon accordingly
  icon <- getDataFileName "art/yi+lambda-fat.pdf"
  _NSImage # alloc >>=
    initWithContentsOfFile (toNSString icon) >>=
    flip setApplicationIconImage app

  -- Initialize the app delegate, which allows quit-on-window-close
  controller <- autonew _YiController >>= return . toYiController
  app # setDelegate controller

  -- init menus
  mm <- _NSMenu # alloc >>= init
  mm' <- _NSMenu # alloc >>= init
  mm'' <- _NSMenu # alloc >>= init
  app # setMainMenu mm
  app # setAppleMenu mm'
  app # setWindowsMenu mm''


  -- Create main cocoa window...
  win <- _NSWindow # alloc >>= initWithContentRect (mkRect 0 0 480 340)
  win # setTitle (toNSString "Yi")
  content <- win # AppKit.NSWindow.contentView >>= return . toNSView
  content # setAutoresizingMask allSizable

  -- Update the font configuration
  let fontSize = maybe 0 fromIntegral (configFontSize (configUI cfg))
  let fontGetter = maybe userFixedPitchFontOfSize (fontWithNameSize . toNSString) (configFontName (configUI cfg))
  _NSFont # fontGetter fontSize >>= flip setUserFixedPitchFont _NSFont

  -- Create yi window container
  winContainer <- new _NSSplitView
  (cmd,_) <- content # addSubviewWithTextLine Nothing winContainer

  -- Activate application window
  win # center
  win # setFrameAutosaveName (toNSString "main")
  win # makeKeyAndOrderFront nil
  app # activateIgnoringOtherApps False

  wc <- newIORef []

  let ui = UI win winContainer cmd wc (outCh . singleton) cfg

  cmd # setColors (Style.baseAttributes $ configStyle $ uiConfig ui)

  return (mkUI ui)

-- | Run the main loop
main :: IO ()
main = _YiApplication # sharedApplication >>= run

-- | Clean up and go home
end :: IO ()
end = _YiApplication # sharedApplication >>= terminate_ nil

syncWindows :: Editor -> UI -> [(Window, Bool)] -> [WinInfo] -> IO [WinInfo]
syncWindows e ui = sync
  where 
    sync ws [] = mapM (insert Nothing) ws
    sync [] cs = mapM_ remove cs >> return []
    sync (w:ws) (c:cs)
      | match w c          = (:) <$> update w c <*> sync ws cs
      | L.any (match w) cs = remove c >> sync (w:ws) cs
      | otherwise          = (:) <$> insert (Just $ widget c) w <*> sync ws (c:cs)

    match w c = winkey (fst w) == winkey (window c)

    winbuf = flip findBufferWith e . bufkey

    remove = removeFromSuperview . widget
    insert before (w,f) = update (w,f) =<< newWindow before ui w (winbuf w)
    update (w, False) i = return (i{window = w})
    update (w, True) i = do
      (textview i) # AppKit.NSView.window >>= makeFirstResponder (textview i)
      return (i{window = w})

setColors :: (Has_setBackgroundColor t, Has_setTextColor t) => Style.Attributes -> t -> IO ()
setColors s slf = do
  getColor True  (Style.foreground s) >>= flip setTextColor slf
  getColor False (Style.background s) >>= flip setBackgroundColor slf

-- | Make A new window
newWindow :: Maybe (NSView t) -> UI -> Window -> FBuffer -> IO WinInfo
newWindow before ui win b = do
  v <- alloc _YiTextView >>= initWithFrame (mkRect 0 0 100 100)
  v # setRichText False
  v # setSelectable True
  v # setAlignment nsLeftTextAlignment
  v # sizeToFit
  let sty = configStyle $ uiConfig ui
      ground = Style.baseAttributes sty
  attrs <- convertAttributes $ appEndo (Style.selectedStyle sty) $ ground
  v # setSelectedTextAttributes attrs
  v # setColors ground
  v # textColor >>= flip setInsertionPointColor v

  (ml, view) <- if (isMini win)
   then do
    v # setHorizontallyResizable False
    v # setVerticallyResizable False
    prompt <- newTextLine
    prompt # setStringValue (toNSString $ miniIdentString b)
    prompt # sizeToFit
    prompt # setAutoresizingMask nsViewNotSizable
    prompt # setBordered False
    prompt # setColors ground

    prect <- prompt # frame
    vrect <- v # frame

    hb <- _NSView # alloc >>= initWithFrame (mkRect 0 0 (nsWidth prect + nsWidth vrect) (nsHeight prect))
    v # setFrame (mkRect (nsWidth prect) 0 (nsWidth vrect) (nsHeight prect))
    v # setAutoresizingMask nsViewWidthSizable
    hb # addSubview prompt
    hb # addSubview v
    hb # setAutoresizingMask nsViewWidthSizable

    brect <- (uiBox ui) # bounds
    hb # setFrame (mkRect 0 0 (nsWidth brect) (nsHeight prect))

    (uiBox ui) # addSubview hb
    dummy <- _NSTextField # alloc >>= init

    return (dummy, hb)
   else do
    v # setHorizontallyResizable True
    v # setVerticallyResizable True
    
    when (not $ configLineWrap $ uiConfig ui) $ do
      tc <- v # textContainer
      NSSize _ h <- tc # containerSize
      tc # setContainerSize (NSSize 1.0e7 h)
      tc # setWidthTracksTextView False

    scroll <- new _YiScrollView
    scroll # setDocumentView v
    scroll # setAutoresizingMask allSizable

    scroll # setHasVerticalScroller True
    scroll # setHasHorizontalScroller False
    scroll # setAutohidesScrollers (configAutoHideScrollBar $ uiConfig ui)
    scroll # setIVar _leftScroller (configLeftSideScrollBar $ uiConfig ui)
    addSubviewWithTextLine before scroll (uiBox ui)

  -- TODO: Support focused modeline...
  ml # setColors (Style.modelineAttributes sty)
  s <- newTextStorage (configStyle $ uiConfig ui) (snd $ runBuffer win b revertPendingUpdatesB) win
  layoutManager v >>= replaceTextStorage s

  responds <- layoutManager v >>= respondsToSelector (getSelectorForName "setAllowsNonContiguousLayout:")
  when responds $ layoutManager v >>= setAllowsNonContiguousLayout True

  k <- newUnique
  flip (setIVar _runBuffer) v $ \act -> do
    wCache <- readIORef (windowCache ui)
    uiActionCh ui $ makeAction $ do
      (modA windowsA) $ fromJust . (PL.move $ fromJust $ L.findIndex ((k ==) . wikey) wCache)
      withGivenBufferAndWindow0 win (bkey b) act

  return $ WinInfo 
    { wikey    = k
    , window   = win
    , textview = v
    , modeline = ml
    , widget   = view
    , storage  = s
    }

getSelectedRegions :: BufferM [NSRange]
getSelectedRegions = do
  rect <- getA rectangleSelectionA
  if (not rect)
    then singleton <$> mkRegionRange <$> getSelectRegionB
    else do
      (reg, x1, x2) <- getRectangle
      ls <- fmap (fromIntegral . L.length) <$> lines' <$> readRegionB reg
      return $ fmap mkRegionRange $ catMaybes $ snd $ L.mapAccumL
        (lineRegions (fromIntegral x1) (fromIntegral x2)) (regionStart reg) ls
  where
    lineRegions :: Size -> Size -> Point -> Size -> (Point, Maybe Region)
    lineRegions x1 x2 p l 
      | l <= x1   = (p +~ succ l, Nothing)
      | l <= x2   = (p +~ succ l, Just $ mkRegion (p+~x1) (p +~ l))
      | otherwise = (p +~ succ l, Just $ mkRegion (p+~x1) (p +~ x2))


refresh :: UI -> Editor -> IO ()
refresh ui e = withAutoreleasePool $ logNSException "refresh" $ do
    _YiApplication # sharedApplication >>=
      pushClipboard (snd $ runEditor (uiFullConfig ui) getRegE e) . toYiApplication
  
    (uiCmdLine ui) # setStringValue (toNSString $ L.intercalate "\n" $ statusLine e)

    cache <- readRef $ windowCache ui
    (uiWindow ui) # setAutodisplay False -- avoid redrawing while window syncing
    cache' <- syncWindows e ui (toList $ PL.withFocus $ windows e) cache
    writeRef (windowCache ui) cache'
    (uiBox ui) # adjustSubviews -- FIX: maybe it is not needed
    (uiWindow ui) # setAutodisplay True -- reenable automatic redrawing

    forM_ cache' $ \w ->
        do let buf = findBufferWith (bufkey (window w)) e
           (storage w) # setMonospaceFont -- FIXME: Why is this needed for mini buffers?
           (storage w) # setTextStorageBuffer e buf

           let ((p0,txt,rs),_) = runBuffer (window w) buf $
                 (,,) <$> pointB <*> getModeLine (commonNamePrefix e) <*> getSelectedRegions
           a <- castObject <$> _NSMutableArray # array :: IO (NSMutableArray ())
           mapM_ ((flip addObject a =<<) . flip valueWithRange _NSValue) rs
           (textview w) # setSelectedRanges (castObject a)
           (textview w) # scrollRangeToVisible (NSRange (fromIntegral p0) 0)
           (modeline w) # setStringValue (toNSString txt)
           (textview w) # visibleRange >>= flip visibleRangeChanged (storage w)
