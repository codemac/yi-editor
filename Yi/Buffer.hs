 --
-- Copyright (C) 2004 Don Stewart - http://www.cse.unsw.edu.au/~dons
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of
-- the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
-- 02111-1307, USA.
--

-- | The 'Buffer' module defines monadic editing operations over one-dimensional
-- buffers, which maintain a current /point/.

module Yi.Buffer ( BufferRef, FBuffer (..), BufferM, runBuffer, keyB, curLn, indexOfEol,
                   sizeB, pointB, moveToSol, moveTo, lineUp, lineDown,
                   hPutB, newB, Point, Mark, BufferMode(..),
                   moveToEol, gotoLn, gotoLnFrom, offsetFromSol,
                   atSol, atEol, atSof, atEof, leftB, rightB,
                   moveXorEol, moveXorSol, insertN, insertB, deleteN,
                   deleteToEol, indexOfSol, nelemsB, writeB, getfileB,
                   setfileB, deleteNAt, readB, elemsB, undo, redo,
                   getMarkB, getSelectionMarkB, getMarkPointB, setMarkPointB, unsetMarkB, 
                   isUnchangedB, setSyntaxB, regexB, searchB, readAtB,
                   getModeLine, getPercent, forgetPreferCol,
                   clearUndosB, addOverlayB,
                   getDynamicB, setDynamicB,
                   nelemsBH, deleteB, Direction (..),
                    ) where

import Prelude hiding ( error )
import System.FilePath
import Text.Regex.Posix.Wrap    ( Regex  )
import Yi.FastBuffer
import Yi.Undo
import Yi.Style
import Yi.Debug
import Yi.Dynamic
import Control.Monad
import Control.Monad.RWS


-- | Direction of movement inside a buffer
data Direction = Backward 
               | Forward  

--data Unit = Character | Word | Line | Vertical | Paragraph | Page | Document | Searched
--data Operation = Move | Delete | Transpose | Copy


-- In addition to FastBuffer, this manages (among others):
--  * Log of updates mades
--  * Undo

data BufferMode = ReadOnly | ReadWrite

type BufferRef = Int

data FBuffer =
        FBuffer { name   :: !String               -- ^ immutable buffer name
                , bkey   :: !BufferRef            -- ^ immutable unique key
                , file   :: !(Maybe FilePath)     -- ^ maybe a filename associated with this buffer
                , undos  :: !URList               -- ^ undo/redo list
                , rawbuf :: !BufferImpl
                , bmode  :: !BufferMode           -- ^ a read-only bit
                , bufferDynamic :: !DynamicValues -- ^ dynamic components
                , preferCol :: !(Maybe Int)       -- ^ prefered column to arrive at when we do a lineDown / lineUp
                }

newtype BufferM a = BufferM { fromBufferM :: RWS () [Update] FBuffer a }
    deriving (Monad, Functor, MonadWriter [Update], MonadState FBuffer)

instance Eq FBuffer where
   FBuffer { bkey = u } == FBuffer { bkey = v } = u == v

instance Show FBuffer where
    showsPrec _ (FBuffer { bkey = u, name = f }) = showString $ "Buffer #" ++ show u ++ " (" ++ show f ++ ")"

-- | Given a buffer, and some information update the modeline
--
-- N.B. the contents of modelines should be specified by user, and
-- not hardcoded.
--
getModeLine :: BufferM String
getModeLine = do
    col <- offsetFromSol
    pos <- pointB
    ln <- curLn
    p <- indexOfEol
    s <- sizeB
    unchanged <- isUnchangedB
    let pct = if pos == 1 then "Top" else getPercent p s
        chg = if unchanged then "-" else "*"
    nm <- gets name
    return $ 
           chg ++ " "
           ++ nm ++ 
           replicate 5 ' ' ++
           "L" ++ show ln ++ "  " ++ "C" ++ show col ++ 
           replicate 2 ' ' ++ pct

--
-- | Give a point, and the file size, gives us a percent string
--
getPercent :: Int -> Int -> String
getPercent a b = show p ++ "%"
    where p = ceiling ((fromIntegral a) / (fromIntegral b) * 100 :: Double) :: Int


queryBuffer :: (BufferImpl -> x) -> (BufferM x)
queryBuffer f = gets (f . rawbuf)

modifyRawbuf    f x = x {rawbuf        = f (rawbuf        x)}
modifyUndos     f x = x {undos         = f (undos         x)}
modifyFile      f x = x {file          = f (file          x)}
modifyPreferCol f x = x {preferCol     = f (preferCol     x)}
modifyDynamic   f x = x {bufferDynamic = f (bufferDynamic x)}

modifyBuffer :: (BufferImpl -> BufferImpl) -> BufferM ()
modifyBuffer f = modify (modifyRawbuf f)
  
queryAndModify :: (BufferImpl -> (BufferImpl,x)) -> BufferM x
queryAndModify f = do
  b <- gets rawbuf
  let (b',x) = f b
  modify (modifyRawbuf $ const b')
  return x

addOverlayB :: Point -> Point -> Style -> BufferM ()
addOverlayB s e sty = modifyBuffer $ addOverlayBI s e sty

runBuffer :: FBuffer -> BufferM a -> (a, FBuffer, [Update])
runBuffer b f = runRWS (fromBufferM f) () b


hPutB :: FBuffer -> IO FBuffer
hPutB b = do
  let bi = rawbuf b
  case file b of
    Nothing -> error "buffer not associated with a file"
    Just f  -> writeFile f (nelemsBI (sizeBI bi) 0 bi)
  return (b {undos = emptyUR})

clearUndosB :: BufferM ()
clearUndosB = modify $ modifyUndos (const emptyUR) -- Clear the undo list, so the changed "flag" is reset.

getfileB :: BufferM (Maybe FilePath)
getfileB = gets file

setfileB :: FilePath -> BufferM ()
setfileB f = modify $ modifyFile $ const (Just f)

keyB :: FBuffer -> BufferRef
keyB (FBuffer { bkey = u }) = u


isUnchangedB :: BufferM Bool
isUnchangedB = gets (isEmptyUList . undos)


undoRedo f = do
  ur <- gets undos
  (ur',updates) <- queryAndModify (f ur)
  modify $ modifyUndos $ const ur'
  tell updates

undo :: BufferM ()
undo = undoRedo undoUR

redo :: BufferM ()
redo = undoRedo redoUR

-- | Create buffer named @nm@ with contents @s@
newB :: BufferRef -> String -> [Char] -> FBuffer
newB unique nm s = 
    FBuffer { name   = nm
            , bkey   = unique
            , file   = Nothing          -- has name, not connected to a file
            , undos  = emptyUR
            , rawbuf = newBI s
            , bmode  = ReadWrite
            , preferCol = Nothing 
            , bufferDynamic = emptyDV
            }

-- | Number of characters in the buffer
sizeB :: BufferM Int
sizeB = queryBuffer sizeBI

-- | Extract the current point
pointB :: BufferM Int
pointB = queryBuffer pointBI

-- | Return @n@ elems starting at @i@ of the buffer as a list
nelemsB :: Int -> Int -> BufferM [Char]
nelemsB n i = queryBuffer $ nelemsBI n i

-- | Return @n@ elems starting at @i@ of the buffer as a list
nelemsBH :: Int -> Int -> BufferM [(Char,Style)]
nelemsBH n i = queryBuffer $ nelemsBIH n i

------------------------------------------------------------------------
-- Point based operations

-- | Move point in buffer to the given index
moveTo :: Int -> BufferM ()
moveTo x = do 
  forgetPreferCol
  modifyBuffer $ moveToI x

------------------------------------------------------------------------

applyUpdate :: Update -> BufferM ()
applyUpdate update = do
  valid <- queryBuffer (isValidUpdate update)
  when valid $ do
       forgetPreferCol
       reversed <- queryAndModify (getActionB update)
       modify $ modifyUndos $ addUR reversed
       tell [update]
  -- otherwise, just ignore.
    

-- | Write an element into the buffer at the current point
-- This is an unsafe operation, no bounds checks are performed
writeB :: Char -> BufferM ()
writeB c = do 
  off <- pointB
  mapM_ applyUpdate [Delete off 1, Insert off [c]]

------------------------------------------------------------------------

-- | Insert the list at current point, extending size of buffer
insertN :: [Char] -> BufferM ()
insertN cs = do 
  pnt <- pointB
  applyUpdate (Insert pnt cs)

-- | Insert the char at current point, extending size of buffer
insertB :: Char -> BufferM ()
insertB = insertN . return

------------------------------------------------------------------------

-- | @deleteNAt n p@ deletes @n@ characters forwards from position @p@
deleteNAt :: Int -> Int -> BufferM ()
deleteNAt n pos = applyUpdate (Delete pos n)

------------------------------------------------------------------------
-- Line based editing

-- | Return the current line number
curLn :: BufferM Int
curLn = queryBuffer curLnI 

-- | Go to line number @n@. @n@ is indexed from 1. Returns the
-- actual line we went to (which may be not be the requested line,
-- if it was out of range)
gotoLn :: Int -> BufferM Int
gotoLn = queryAndModify . gotoLnI

---------------------------------------------------------------------

-- | Return index of next string in buffer that matches argument
searchB :: [Char] -> BufferM (Maybe Int)
searchB = queryBuffer . searchBI

-- | Set name of syntax highlighting mode
setSyntaxB :: [Char] -> BufferM ()
setSyntaxB = modifyBuffer . setSyntaxBI

-- | Return indices of next string in buffer matched by regex
regexB :: Regex -> BufferM (Maybe (Int,Int))
regexB = queryBuffer . regexBI

---------------------------------------------------------------------

-- | Set a mark in this buffer
setMarkPointB :: Mark -> Int -> BufferM ()
setMarkPointB m pos = modifyBuffer $ setMarkPointBI m pos

getMarkPointB :: Mark -> BufferM Int
getMarkPointB = queryBuffer . getMarkPointBI

unsetMarkB :: BufferM ()
unsetMarkB = modifyBuffer unsetMarkBI

getMarkB :: Maybe String -> BufferM Mark
getMarkB = queryAndModify . getMarkBI

getSelectionMarkB :: BufferM Mark
getSelectionMarkB = queryBuffer getSelectionMarkBI

-- | Move point -1
leftB :: BufferM ()
leftB = leftN 1

-- | Move cursor -n
leftN :: Int -> BufferM ()
leftN n = pointB >>= \p -> moveTo (p - n)

-- | Move cursor +1
rightB :: BufferM ()
rightB = rightN 1

-- | Move cursor +n
rightN :: Int -> BufferM ()
rightN n = pointB >>= \p -> moveTo (p + n)

-- ---------------------------------------------------------------------
-- Line based movement and friends

readPrefCol :: BufferM (Maybe Int)
readPrefCol = gets preferCol

setPrefCol :: Maybe Int -> BufferM ()
setPrefCol c = modify $ modifyPreferCol (const c)

-- | Move point down by @n@ lines. @n@ can be negative.
lineMoveRel :: Int -> BufferM ()
lineMoveRel n = do
  prefCol <- readPrefCol
  targetCol <- case prefCol of
    Nothing -> offsetFromSol
    Just x -> return x
  gotoLnFrom n
  moveXorEol targetCol
  --logPutStrLn $ "lineMoveRel: targetCol = " ++ show targetCol
  setPrefCol (Just targetCol)

forgetPreferCol :: BufferM ()
forgetPreferCol = setPrefCol Nothing

savingPrefCol :: BufferM a -> BufferM a
savingPrefCol f = do
  pc <- gets preferCol
  result <- f
  setPrefCol pc
  return result

-- | Move point up one line
lineUp :: BufferM ()
lineUp = lineMoveRel (-1)

-- | Move point down one line
lineDown :: BufferM ()
lineDown = lineMoveRel 1


-- | Return the contents of the buffer as a list
elemsB :: BufferM [Char]
elemsB = do n <- sizeB
            nelemsB n 0

-- | Read the character at the current point
readB :: BufferM Char
readB = pointB >>= readAtB

-- | Read the character at the given index
-- This is an unsafe operation: character NUL is returned when out of bounds
readAtB :: Int -> BufferM Char
readAtB i = do
    s <- nelemsB 1 i
    return $ case s of
               [c] -> c
               _ -> '\0'

-- | Delete 1 character forward from the current point 
deleteB :: BufferM ()
deleteB = deleteN 1

-- | Delete @n@ characters forward from the current point
deleteN :: Int -> BufferM ()
deleteN n = pointB >>= deleteNAt n

-- | Delete to the end of line, excluding it.
deleteToEol :: BufferM ()
deleteToEol = do
    p <- pointB
    moveToEol
    q <- pointB
    deleteNAt (q-p) p

------------------------------------------------------------------------

-- | Return true if the current point is the start of a line
atSol :: BufferM Bool
atSol = do p <- pointB
           if p == 0 then return True
                     else do c <- readAtB (p-1)
                             return (c == '\n')

-- | Return true if the current point is the end of a line
atEol :: BufferM Bool
atEol = do p <- pointB
           e <- sizeB
           if p == e
                  then return True
                  else do c <- readAtB p
                          return (c == '\n')

-- | True if point at start of file
atSof :: BufferM Bool
atSof = do p <- pointB
           return (p == 0)

-- | True if point at end of file
atEof :: BufferM Bool
atEof = do p <- pointB
           e <- sizeB
           return (p == e)


-- | Offset from start of line
offsetFromSol :: BufferM Int
offsetFromSol = savingPrefCol $ do
    i <- pointB
    moveToSol
    j <- pointB
    moveTo i
    return (i - j)
{-# INLINE offsetFromSol #-}

-- | Index of start of line
indexOfSol :: BufferM Int
indexOfSol = savingPrefCol $ do
    i <- pointB
    j <- offsetFromSol
    return (i - j)
{-# INLINE indexOfSol #-}

-- | Index of end of line
indexOfEol :: BufferM Int
indexOfEol = savingPrefCol $ do
    i <- pointB
    moveToEol
    j <- pointB
    moveTo i
    return j
{-# INLINE indexOfEol #-}


-- | Move using the direction specified by the 1st argument, until
-- either we've moved @n@, the 2nd argument, or @p@ the 3rd argument
-- is True
moveAXuntil :: BufferM () -> Int -> (BufferM Bool) -> BufferM ()
moveAXuntil f x p
    | x <= 0    = return ()
    | otherwise = do -- will be slow on long lines...
        let loop 0 = return ()
            loop i = do r <- p
                        when (not r) $ f >> loop (i-1)
        savingPrefCol (loop x)
{-# INLINE moveAXuntil #-}

-- | Move @x@ chars back, or to the sol, whichever is less
moveXorSol :: Int -> BufferM ()
moveXorSol x = moveAXuntil leftB x atSol

-- | Move @x@ chars forward, or to the eol, whichever is less
moveXorEol :: Int -> BufferM ()
moveXorEol x = moveAXuntil rightB x atEol


-- | Go to line indexed from current point
gotoLnFrom :: Int -> BufferM Int
gotoLnFrom x = do 
  l <- curLn
  gotoLn (x+l)

-- | Move point to start of line
moveToSol :: BufferM ()
moveToSol = sizeB >>= moveXorSol  

-- | Move point to end of line
moveToEol :: BufferM ()
moveToEol = sizeB >>= moveXorEol 

getDynamicB :: Initializable a => BufferM a
getDynamicB = gets (getDynamicValue . bufferDynamic)

-- | Insert a value into the extensible state, keyed by its type
setDynamicB :: Initializable a => a -> BufferM ()
setDynamicB x = modify $ modifyDynamic $ setDynamicValue x
