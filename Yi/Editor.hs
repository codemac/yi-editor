-- 
-- Copyright (c) 2004 Don Stewart - http://www.cse.unsw.edu.au/~dons
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

--
-- | The editor state. This is the machine that Core instructions
-- manipulate.  The editor manages buffers. One buffer is always in
-- focus.
--

module Yi.Editor where

import Yi.Buffer                ( Buffer(newB, keyB, hNewB, finaliseB) )
import Yi.FastBuffer
import Yi.Regex                 ( Regex )
import Yi.Window
import Yi.Style                 ( ui, UIStyle )
import Yi.Map as M

import Data.List                ( elemIndex, find )
import Data.IORef               ( newIORef, readIORef, writeIORef, IORef )
import Data.Unique              ( Unique )
import System.IO.Unsafe         ( unsafePerformIO )
import Control.Monad            ( liftM )
import Control.Concurrent       ( killThread, ThreadId )
import Control.Concurrent.Chan  ( Chan )
import Control.Concurrent.MVar

--
-- | The editor state, manipulated by Core instructoins.
-- The editor stores all the buffers, which correspond to opened files.
-- Windows are views (or port holes) on to buffers, and multiple windows
-- may be opened onto the one buffer. A distinguished /window/ is stored
-- explicitly: the command line.
--
-- Some instructions manipulate buffers, and some just manipulate
-- windows (e.g. scrolling and splitting).
--
-- The order windows are displayed on the screen is encoded in their
-- order in the @windows@ list.
--
-- TODO Windows should be MVar'd as well.
--
-- TODO the command line is a vi\/emacs specific concept.
--
data Buffer a => GenEditor a = 
    Editor {
        buffers   :: !(M.Map Unique a)      -- ^ all the buffers
       ,windows   :: !(M.Map Unique Window) -- ^ all the windows
       ,cmdline   :: !String                    -- ^ the command line
       ,cmdlinefocus :: !Bool                   -- ^ cmdline has focus
       ,yreg      :: !String                    -- ^ yank register
       ,regex     :: !(Maybe (String,Regex))    -- ^ most recent regex
       ,curwin    :: !(Maybe Unique)            -- ^ the window with focus
       ,curkeymap :: [Char] -> [Action]         -- ^ user-configurable keymap
       ,scrsize   :: !(Int,Int)                 -- ^ screen size
       ,uistyle   :: !UIStyle                   -- ^ ui colours
       ,input     :: Chan Char                  -- ^ input stream
       ,threads   :: [ThreadId]                 -- ^ all our threads

       ,reboot    :: IO ()                      -- our reboot function
       ,reload    :: IO Config                  -- reload config function
    }

--
-- Instantiate the editor with a basic buffer type
--
type Buffer' = FBuffer
type Editor  = GenEditor Buffer'

-- ---------------------------------------------------------------------
--
-- | The actual editor state
--
-- TODO get rid of big lock on state (buffers themselves are locked)
-- We'd have to lock individual components of the state, however...
--
-- ToDo abolish this, in favour of a state monad.
--
-- state :: Buffer a => MVar (IORef (GenEditor a))
state :: MVar (IORef Editor)
state = unsafePerformIO $ do
            ref  <- newIORef emptyEditor
            newMVar ref
{-# NOINLINE state #-}

--
-- The ui needs to know if that state has changed
--
editorModified :: MVar ()
editorModified = unsafePerformIO $ newMVar ()
{-# NOINLINE editorModified #-}

--
-- | The initial state
--
emptyEditor :: Editor
emptyEditor = Editor {
        buffers      = M.empty 
       ,windows      = M.empty
       ,cmdline      = []
       ,cmdlinefocus = False
       ,yreg         = []
       ,regex        = Nothing
       ,curwin       = Nothing
       ,curkeymap    = error "No keymap defined."
       ,scrsize      = (0,0)
       ,uistyle      = Yi.Style.ui
       ,input        = error "No channel open"
       ,threads      = []
       ,reboot       = return ()
       ,reload       = error "No reload function"
    }

-- 
-- | Read the editor state, with a pure action
-- 
readEditor :: (Editor -> b) -> IO b
readEditor f = withMVar state $ \ref -> return . f =<< readIORef ref

--
-- | Read the editor state, with an IO action
--
withEditor :: (Editor -> IO ()) -> IO ()
withEditor f = withMVar state $ \ref -> f =<< readIORef ref

--
-- | Modify the contents, using an IO action.
--
modifyEditor_ :: (Editor -> IO Editor) -> IO ()
modifyEditor_ f = do
    modifyMVar_ state $ \r ->
            readIORef r >>= f >>= writeIORef r >> return r
    tryPutMVar editorModified ()
    return ()

--
-- | Variation on modifyEditor_ that lets you return a value
--
modifyEditor :: (Editor -> IO (Editor,b)) -> IO b
modifyEditor f = do
    b <- modifyMVar state $ \r -> do
                    v  <- readIORef r
                    (v',b) <- f v
                    writeIORef r v'
                    return (r,b)
    tryPutMVar editorModified ()
    return b

-- ---------------------------------------------------------------------
-- Buffer operations
--
-- | Create a new buffer filling with contents of file.
--
hNewBuffer :: FilePath -> IO Buffer'
hNewBuffer f = 
    modifyEditor $ \e@(Editor{buffers=bs}) -> do
        b <- hNewB f
        let e' = e { buffers = M.insert (keyB b) b bs } :: Editor
        return (e', b)

--
-- | Create and fill a new buffer, using contents of string.
--
stringToNewBuffer :: FilePath -> String -> IO Buffer'
stringToNewBuffer f cs =
    modifyEditor $ \e@(Editor{buffers=bs}) -> do
        b <- newB f cs
        let e' = e { buffers = M.insert (keyB b) b bs } :: Editor
        return (e', b)

--
-- | return the buffers we have
-- TODO we need to order the buffers some how.
--
-- getBuffers :: Buffer a => IO [a]
--
getBuffers :: IO [Buffer']
getBuffers = readEditor $ M.elems . buffers

--
-- | get the number of buffers we have
--
sizeBuffers :: IO Int                        
sizeBuffers = readEditor $ \e -> M.size (buffers (e :: Editor))

--
-- | Find buffer with this key
-- 
findBufferWith :: Editor -> Unique -> Buffer'
findBufferWith e k = 
    case M.lookup k (buffers e) of
        Just b  -> b
        Nothing -> error "Editor.findBufferWith: no buffer has this key"

--
-- | Safely lookup buffer using it's key.
--
getBufferWith :: Unique -> IO Buffer'
getBufferWith u = readEditor $ \e -> findBufferWith (e :: Editor) u

-- | Return the next buffer
nextBuffer :: IO Buffer'
nextBuffer = shiftBuffer (+1)

-- | Return the prev buffer
prevBuffer :: IO Buffer'
prevBuffer = shiftBuffer (subtract 1)

-- | Return the nth buffer in the buffer list, module buffer count
bufferAt :: Int -> IO Buffer'
bufferAt n = shiftBuffer (const n)

-- | Return the buffer using a function applied to the current window's
-- buffer's index.
shiftBuffer :: (Int -> Int) -> IO Buffer'
shiftBuffer f = readEditor $ \e ->
    let bs  = M.elems $ buffers (e :: Editor)
        win = findWindowWith e (curwin e)
        buf = findBufferWith e (bufkey win)
    in case elemIndex buf bs of
        Nothing -> error "Editor: current buffer has been lost."
        Just i -> let l = length bs in bs !! ((f i) `mod` l)

------------------------------------------------------------------------
-- | Window manipulation

-- | Create a new window onto this buffer.
-- Top of screen of other windows needs to get adjusted
-- As does their modeslines.
--
newWindow :: Buffer' -> IO Window
newWindow b = modifyEditor $ \e -> do
    let (h,w) = scrsize e
        wls   = M.elems $ windows e
        (y,r) = getY h (1 + (length wls))   -- should be h-1..
    wls' <- resizeAll e wls y w
    wls''<- if wls' == [] then return wls' else turnOnML e wls'
    win  <- emptyWindow b (y+r,w) 
    win' <- if wls == [] then return win else liftM head $ turnOnML e [win]
    let e' = e { windows = M.fromList $ mkAssoc (win':wls'') }
    return (e', win')

--
-- | Delete the focused window
--
-- Delete the buffer, if this is the last window onto that buffer That
-- is, we abandon buffers that have no windows on to them. To program
-- 'hidden' behaviour, you'll have to keep a reference to the buffer
-- yourself, somehow. Hmm.
--
deleteWindow :: (Maybe Window) -> IO ()
deleteWindow Nothing  = return ()
deleteWindow (Just win) = modifyEditor_ $ \e -> do
    let ws    = M.delete (key win) (windows e) -- delete window
        oldkey= bufkey win
        wls   = M.elems ws
        x     = snd $ scrsize e
        (y,r) = getY ((fst $ scrsize e) - 1) (length wls) -- why -1?

    -- find any windows onto the same buffer, if none, delete this buffer
    e' <- case find (\w -> bufkey w == oldkey) wls of
        Just _  -> return e
        Nothing -> do
            let b = findBufferWith e oldkey
            finaliseB b
            return $ e { buffers = M.delete oldkey (buffers e) }

    -- resize, then grab a random window
    wls' <- resizeAll e' wls y x
    case wls' of   
        []       -> return e' { windows = M.empty }
        (win':xs) -> do
            let fm = M.fromList $ mkAssoc wls'
            win'' <- resize (y+r) x win' (findBufferWith e' (bufkey win'))
            let win''' = if xs == [] then win'' { mode = Nothing } else win''
            let e'' = e' { windows = M.insert (key win''') win''' fm }
            setWindow' e'' win'''

-- | Update height of windows in window set
resizeAll :: Editor -> [Window] -> Int -> Int -> IO [Window]
resizeAll e wls y x = flip mapM wls (\w -> 
                            resize y x w $ findBufferWith e (bufkey w))

-- | Reset the heights and widths of all the windows
doResizeAll :: (Int,Int) -> IO ()
doResizeAll sz@(h,w) = modifyEditor_ $ \e -> do
    let wls   = M.elems (windows e)
        (y,r) = getY h (length wls) -- why -1?

    wls'  <- mapM (doresize e w y) (init wls)
    wls'' <- let win = last wls 
            in doresize e w (y+r-1) win >>= \w' -> return (w' : wls')

    return e { scrsize = sz, windows = M.fromList $ mkAssoc wls'' }

    where doresize e x y win = resize y x win $ findBufferWith e (bufkey win)

-- | Turn on modelines of all windows
turnOnML :: Editor -> [Window] -> IO [Window]
turnOnML e = mapM $ \w -> do let win = w { mode = Just undefined }
                             m <- updateModeLine win $ findBufferWith e (bufkey w)
                             return w { mode = m }

-- | calculate window heights, given all the windows and current height
-- doesn't take into account modelines
getY :: Int -> Int -> (Int,Int)
getY h 0 = (h, 0)
getY h 1 = (h, 0)
getY h l = h `quotRem` l

-- | turn a list of windows into an association list suitable for fromList
mkAssoc :: [Window] -> [(Unique,Window)]
mkAssoc []     = []
mkAssoc (w:ws) = (key w, w) : mkAssoc ws

-- ---------------------------------------------------------------------
-- | Get all the windows
-- TODO by key
--
getWindows :: Editor -> [Window]
getWindows = M.elems . windows

--
-- | Get current window
--
getWindow :: IO (Maybe Window)
getWindow = readEditor getWindowOf

--
-- | Get window, from the given editor state.
--
getWindowOf :: Editor -> (Maybe Window)
getWindowOf e = case curwin e of
                    Nothing -> Nothing
                    k       -> Just $ findWindowWith e k

--
-- | Get index of current window in window list
--
getWindowIndOf :: Editor -> (Maybe Int)
getWindowIndOf e = case curwin e of    
        Nothing -> Nothing
        k       -> let win = findWindowWith e k
                   in elemIndex win (M.elems $ windows e)

--
-- | Set current window
-- !! reset the buffer point from the window point
-- 
-- Factor in shift focus.
--
setWindow :: Window -> IO ()
setWindow w = modifyEditor_ $ \e -> (setWindow' e w :: IO Editor)

--
-- | Internal function to update window on focus or creation.
--
setWindow' :: Editor -> Window -> IO Editor
setWindow' e w = do
    let fm = windows e
    let b  = findBufferWith e (bufkey w)
    w' <- resetPoint w b
    return $ e { windows = M.insert (key w') w' fm, curwin = Just $ key w' } 

--
-- | How many windows do we have
--
sizeWindows :: IO Int
sizeWindows = readEditor $ \e -> length $ M.elems (windows e)

--
-- | Find the window with this key
--
findWindowWith :: Editor -> (Maybe Unique) -> Window
findWindowWith _ Nothing  = error "Editor: no key"
findWindowWith e (Just k) = 
    case M.lookup k (windows e) of
            Just w  -> w
            Nothing -> error "Editor: no window has this key"

------------------------------------------------------------------------
--
-- | Perform action with current window
--
withWindow_ :: (Window -> Buffer' -> IO Window) -> IO ()
withWindow_ f = modifyEditor_ $ \e -> do
        let w = findWindowWith e (curwin e)
            b = findBufferWith e (bufkey w)
        w' <- f w b
        m'     <- updateModeLine w' b
        let w'' = w' { mode = m' }
            ws = windows e
            e' = e { windows = M.insert (key w'') w'' ws }
        return e'

--
-- | Variation on withWindow_ that can return a value
--
withWindow :: (Window -> Buffer' -> IO (Window,b)) -> IO b
withWindow f = modifyEditor $ \e -> do
        let w = findWindowWith e (curwin e)
            b = findBufferWith e (bufkey w)
        (w',v) <- f w b
        m'     <- updateModeLine w' b
        let w'' = w' { mode = m' }
            ws = windows e
            e' = e { windows = M.insert (key w'') w'' ws }
        return (e',v)

-- ---------------------------------------------------------------------
-- | Rotate focus to the next window
--
nextWindow :: IO ()
nextWindow = shiftFocus (+1)

--
-- | Rotate focus to the previous window
--
prevWindow :: IO ()
prevWindow = shiftFocus (subtract 1)

--
-- | Shift focus to the nth window, modulo the number of windows
--
windowAt :: Int -> IO ()
windowAt n = shiftFocus (const n)

--
-- | Set the new current window using a function applied to the old
-- window's index
-- !! reset buffer point from window point
--
shiftFocus :: (Int -> Int) -> IO ()
shiftFocus f = modifyEditor_ $ \e -> do
    let ws  = M.elems $ windows e    -- hack
        k   = curwin e
        win = findWindowWith e k
    case elemIndex win ws of
        Nothing -> error "Editor: current window has been lost."
        Just i -> let w = ws !! ((f i) `mod` (length ws)) 
                  in (setWindow' e w :: IO Editor)

-- ---------------------------------------------------------------------
-- | Given a keymap function, set the user-defineable key map to that function
--
setUserSettings :: Config -> IO () -> IO Config -> IO ()
setUserSettings (Config km sty) fn fn' = 
    modifyEditor_ $ \e -> 
        return $ (e { curkeymap = km, 
                     uistyle = sty, 
                     reboot = fn,
                     reload = fn' } :: Editor)

--
-- | retrieve the user-defineable key map
--
getKeyBinds :: IO ([Char] -> [Action])
getKeyBinds = readEditor curkeymap

-- ---------------------------------------------------------------------

--
-- | Shut down all of our threads. Should free buffers etc.
--
shutdown :: IO ()
shutdown = do ts <- readEditor threads
              mapM_ killThread ts
              modifyEditor_ $ const (return emptyEditor)

-- ---------------------------------------------------------------------
--
-- | All the user-defineable settings. This is the type of the data in
-- ~/.yi/Config.hs. All user defineable values will eventually be in
-- this structure. A value of this type is passed from Boot.hs to Yi.hs
-- in the dynamically loaded edition of yi.
--
data Config = Config {
            keymap :: [Char] -> [Action]       -- ^ bind keys to editor actions
           ,style  :: UIStyle
    }

-- ---------------------------------------------------------------------
-- | The type of user-bindable functions
--
type Action = IO ()
