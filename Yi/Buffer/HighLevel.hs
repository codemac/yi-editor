{-# LANGUAGE DeriveDataTypeable #-}
-- Copyright (C) 2008 JP Bernardy
module Yi.Buffer.HighLevel where

import Control.Applicative
import Control.Monad.State
import Data.Char
import Data.Dynamic

import Yi.Buffer
import Yi.Buffer.Normal
import Yi.Buffer.Region
import Yi.String
import Yi.Window
import Yi.Dynamic

-- ---------------------------------------------------------------------
-- Movement operations

-- | Move point to start of line
moveToSol :: BufferM ()
moveToSol = maybeMoveB Line Backward

-- | Move point to end of line
moveToEol :: BufferM ()
moveToEol = maybeMoveB Line Forward

-- | Move cursor to origin
topB :: BufferM ()
topB = moveTo 0

-- | Move cursor to end of buffer
botB :: BufferM ()
botB = moveTo =<< sizeB

-- | Move @x@ chars back, or to the sol, whichever is less
moveXorSol :: Int -> BufferM ()
moveXorSol x = replicateM_ x $ do c <- atSol; when (not c) leftB

-- | Move @x@ chars forward, or to the eol, whichever is less
moveXorEol :: Int -> BufferM ()
moveXorEol x = replicateM_ x $ do c <- atEol; when (not c) rightB

-- | Move to first char of next word forwards
nextWordB :: BufferM ()
nextWordB = moveB Word Forward

-- | Move to first char of next word backwards
prevWordB :: BufferM ()
prevWordB = moveB Word Backward

-- * Char-based movement actions.

-- | Move to the next occurence of @c@
nextCInc :: Char -> BufferM ()
nextCInc c = doUntilB_ ((c ==) <$> readB) rightB

-- | Move to the character before the next occurence of @c@
nextCExc :: Char -> BufferM ()
nextCExc c = nextCInc c >> leftB

-- | Move to the previous occurence of @c@
prevCInc :: Char -> BufferM ()
prevCInc c = doUntilB_ ((c ==) <$> readB) leftB

-- | Move to the character after the previous occurence of @c@
prevCExc :: Char -> BufferM ()
prevCExc c = prevCInc c >> rightB

-- | Move to first non-space character in this line
firstNonSpaceB :: BufferM ()
firstNonSpaceB = do moveToSol
                    untilB_ ((||) <$> atEol <*> ((not . isSpace) <$> readB)) rightB





------------

-- | Move down next @n@ paragraphs
nextNParagraphs :: Int -> BufferM ()
nextNParagraphs n = replicateM_ n $ moveB Paragraph Forward

-- | Move up prev @n@ paragraphs
prevNParagraphs :: Int -> BufferM ()
prevNParagraphs n = replicateM_ n $ moveB Paragraph Backward


-----------------------------------------------------------------------
-- Queries

-- | Return true if the current point is the start of a line
atSol :: BufferM Bool
atSol = atBoundaryB Line Backward

-- | Return true if the current point is the end of a line
atEol :: BufferM Bool
atEol = atBoundaryB Line Forward

-- | True if point at start of file
atSof :: BufferM Bool
atSof = atBoundaryB Document Backward

-- | True if point at end of file
atEof :: BufferM Bool
atEof = atBoundaryB Document Forward

-- | Get the current line and column number
getLineAndCol :: BufferM (Int, Int)
getLineAndCol = do
  lineNo <- curLn
  colNo  <- offsetFromSol
  return (lineNo, colNo)

-- | Read the line the point is on
readLnB :: BufferM String
readLnB = readUnitB Line

-- | Read from point to end of line
readRestOfLnB :: BufferM String
readRestOfLnB = readRegionB =<< regionOfPartB Line Forward

--------------------------
-- Deletes

-- | Delete one character backward
bdeleteB :: BufferM ()
bdeleteB = deleteB Character Backward

-- | Delete forward whitespace or non-whitespace depending on
-- the character under point.
killWordB :: BufferM ()
killWordB = deleteB Word Forward

-- | Delete backward whitespace or non-whitespace depending on
-- the character before point.
bkillWordB :: BufferM ()
bkillWordB = deleteB Word Backward


----------------------------------------
-- Transform operations

-- | capitalise the word under the cursor
uppercaseWordB :: BufferM ()
uppercaseWordB = transformB (map toUpper) Word Forward

-- | lowerise word under the cursor
lowercaseWordB :: BufferM ()
lowercaseWordB = transformB (map toLower) Word Forward

-- | capitalise the first letter of this word
capitaliseWordB :: BufferM ()
capitaliseWordB = transformB capitalizeFirst Word Forward


-- | Delete to the end of line, excluding it.
deleteToEol :: BufferM ()
deleteToEol = deleteRegionB =<< regionOfPartB Line Forward

-- | Transpose two characters, (the Emacs C-t action)
swapB :: BufferM ()
swapB = do eol <- atEol
           when eol leftB
           transposeB Character Forward

-- ----------------------------------------------------
-- | Marks

-- | Set the current buffer mark
setSelectionMarkPointB :: Int -> BufferM ()
setSelectionMarkPointB pos = do m <- getSelectionMarkB; setMarkPointB m pos

-- | Get the current buffer mark
getSelectionMarkPointB :: BufferM Int
getSelectionMarkPointB = do m <- getSelectionMarkB; getMarkPointB m

-- | Exchange point & mark.
-- Maybe this is better put in Emacs\/Mg common file
exchangePointAndMarkB :: BufferM ()
exchangePointAndMarkB = do m <- getSelectionMarkPointB
                           p <- pointB
                           setSelectionMarkPointB p
                           moveTo m

getBookmarkB :: String -> BufferM Mark
getBookmarkB nm = getMarkB (Just nm)

-- ---------------------------------------------------------------------
-- Buffer operations

data BufferFileInfo =
    BufferFileInfo { bufInfoFileName :: FilePath
                   , bufInfoSize     :: Int
                   , bufInfoLineNo   :: Int
                   , bufInfoColNo    :: Int
                   , bufInfoCharNo   :: Int
                   , bufInfoPercent  :: String
                   , bufInfoModified :: Bool
                   }

-- | File info, size in chars, line no, col num, char num, percent
bufInfoB :: BufferM BufferFileInfo
bufInfoB = do
    s <- sizeB
    p <- pointB
    m <- isUnchangedB
    l <- curLn
    c <- offsetFromSol
    nm <- gets name
    let bufInfo = BufferFileInfo { bufInfoFileName = nm
                                 , bufInfoSize     = s
                                 , bufInfoLineNo   = l
                                 , bufInfoColNo    = c
                                 , bufInfoCharNo   = p
                                 , bufInfoPercent  = getPercent p s
                                 , bufInfoModified = not m
                                 }
    return bufInfo

-----------------------------
-- Window-related operations

-- | Scroll up 1 screen
upScreenB :: BufferM ()
upScreenB = upScreensB 1

-- | Scroll down 1 screen
downScreenB :: BufferM ()
downScreenB = downScreensB 1

-- | Scroll up n screens
upScreensB :: Int -> BufferM ()
upScreensB = moveScreenB Forward

-- | Scroll down n screens
downScreensB :: Int -> BufferM ()
downScreensB = moveScreenB Backward

moveScreenB :: Direction -> Int -> BufferM ()
moveScreenB dir n = do h <- askWindow height
                       case dir of
                         Forward -> gotoLnFrom (- (n * (h - 1)))
                         Backward -> gotoLnFrom $ n * (h - 1)
                       moveToSol

-- | Move to @n@ lines down from top of screen
downFromTosB :: Int -> BufferM ()
downFromTosB n = do
  moveTo =<< askWindow tospnt
  replicateM_ n lineDown

-- | Move to @n@ lines up from the bottom of the screen
upFromBosB :: Int -> BufferM ()
upFromBosB n = do
  moveTo =<< askWindow bospnt
  moveToSol
  replicateM_ n lineUp

-- | Move to middle line in screen
middleB :: BufferM ()
middleB = do
  w <- askWindow id
  moveTo (tospnt w)
  replicateM_ (height w `div` 2) lineDown

-- | Extend the given region to boundaries of the text unit.
-- For instance one can extend the selection to to complete lines, or
-- paragraphs.
extendRegionToBoundaries :: TextUnit -> BoundarySide -> BoundarySide -> Region -> BufferM Region
extendRegionToBoundaries unit bs1 bs2 region = do
  moveTo $ regionStart region
  genMaybeMoveB unit (Backward, bs1) Backward
  start <- pointB
  moveTo $ regionEnd region
  genMoveB unit (Forward, bs2) Forward
  stop <- pointB
  return $ mkRegion start stop

unitWiseRegion :: TextUnit -> Region -> BufferM Region
unitWiseRegion unit = extendRegionToBoundaries unit InsideBound OutsideBound


-- TODO: either decide this is evil and contain it to Vim, or embrace it and move it to the
-- Buffer record.
newtype SelectionStyle = SelectionStyle TextUnit
  deriving (Typeable)

instance Initializable SelectionStyle where
  initial = SelectionStyle Character

-- | Get the current region boundaries
getSelectRegionB :: BufferM Region
getSelectRegionB = do
  m <- getMarkPointB =<< getSelectionMarkB
  p <- pointB
  let region = mkRegion m p
  SelectionStyle unit <- getDynamicB
  unitWiseRegion unit region

