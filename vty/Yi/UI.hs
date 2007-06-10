{-# OPTIONS -#include "YiUtils.h" #-}
--
-- Copyright (C) 2004-5 Don Stewart - http://www.cse.unsw.edu.au/~dons
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
-- Derived from: riot/UI.hs
--
--      Copyright (c) Tuomo Valkonen 2004.
--
-- Released under the same license.
--

-- | This module defines a user interface implemented using ncurses.

module Yi.UI (

        -- * UI initialisation
        start, end, suspend, main,

        -- * Refresh
        refreshAll, scheduleRefresh, prepareAction,

        -- * Window manipulation
        newWindow, enlargeWindow, shrinkWindow, deleteWindow,
        hasRoomForExtraWindow, setWindowBuffer, setWindow,
        withWindow0, getWindow, getWindows,

        -- * Command line
        setCmdLine,

        -- * UI type, abstract.
        UI,

        module Yi.Event   -- UIs need to export the symbolic key names


  )   where

import Prelude hiding (error)

import Yi.Buffer (Point, FBuffer (..), pointB, curLn, getMarkPointB, getSelectionMarkB, 
                  getModeLine, runBuffer )
import Yi.FastBuffer( nelemsBIH ) -- gah this is ugly
import Yi.Editor
import Yi.Window as Window
import Yi.Style
import Yi.Vty hiding (def, black, red, green, yellow, blue, magenta, cyan, white)
import Yi.Event
import Yi.Debug
import Yi.Monad

import Control.Concurrent
import Control.Concurrent.Chan
import Control.Exception
import Control.Monad.Reader

import Data.Traversable as T
import Data.List
import Data.Unique
import Data.Maybe
import Data.Char (ord,chr)
import qualified Data.Map as M
import qualified Yi.WindowSet as WS
import Data.IORef
import System.Exit
import System.Posix.Signals         ( raiseSignal, sigTSTP )

import qualified Data.ByteString.Char8 as B

------------------------------------------------------------------------

data UI = UI { 
              vty       :: Vty                     -- ^ Vty
             ,scrsize   :: !(IORef (Int,Int))  -- ^ screen size
             ,uiThread  :: ThreadId
             ,cmdline   :: IORef String
             ,uiRefresh :: MVar ()
             ,windows   :: IORef (WS.WindowSet Window)     -- ^ all the windows
             }

-- | Initialise the ui
start :: FBuffer -> EditorM (Chan Yi.Event.Event, UI)
start buf = do
  editor <- ask
  liftIO $ do 
          w0 <- emptyWindow False buf (1,1)
          ws0 <- newIORef  (WS.new w0)
          v <- mkVty
          (x,y) <- Yi.Vty.getSize v
          s <- newIORef (y,x)
          -- fork input-reading thread. important to block *thread* on getKey
          -- otherwise all threads will block waiting for input
          ch <- newChan
          t <- myThreadId
          cmd <- newIORef ""
          tuiRefresh <- newEmptyMVar
          let result = UI v s t cmd tuiRefresh ws0
              -- | Action to read characters into a channel
              getcLoop editor v s ch = repeatM_ $ getKey editor v s >>= writeChan ch

              -- | Read a key. UIs need to define a method for getting events.
              getKey editor v sz = do 
                event <- getEvent v
                case event of 
                  (EvResize x y) -> do logPutStrLn $ "UI: EvResize: " ++ show (x,y)
                                       writeIORef sz (y,x) >> runReaderT (refreshAll result) editor >> getKey editor v sz
                  _ -> return (fromVtyEvent event)
          forkIO $ getcLoop editor v s ch 
          return (ch, result)
        

main :: IORef Editor -> UI -> IO ()
main editor ui = do
  e <- readIORef editor
  let
      -- | When the editor state isn't being modified, refresh, then wait for
      -- it to be modified again. 
      refreshLoop :: IO ()
      refreshLoop = repeatM_ $ do 
                      takeMVar (uiRefresh ui)
                      handleJust ioErrors (\except -> do 
                                             logPutStrLn "refresh crashed with IO Error"
                                             logError $ show $ except)
                                     (runReaderT (refresh ui) editor)
  scheduleRefresh' ui
  logPutStrLn "refreshLoop started"
  refreshLoop
  

-- | Clean up and go home
end :: UI -> IO ()
end i = do  
  Yi.Vty.shutdown (vty i)
  throwTo (uiThread i) (ExitException ExitSuccess)

-- | Suspend the program
suspend :: UI -> EditorM ()
suspend _ = lift $ raiseSignal sigTSTP

-- | Find the current screen height and width.
screenSize :: UI -> EditorM (Int, Int)
screenSize ui = lift . readIORef . scrsize $ ui


fromVtyEvent :: Yi.Vty.Event -> Yi.Event.Event
fromVtyEvent (EvKey k mods) = Event (fromVtyKey k) (map fromVtyMod mods)
fromVtyEvent _ = error "fromVtyEvent: unsupported event encountered."


fromVtyKey :: Yi.Vty.Key -> Yi.Event.Key
fromVtyKey (Yi.Vty.KEsc     ) = Yi.Event.KEsc      
fromVtyKey (Yi.Vty.KFun x   ) = Yi.Event.KFun x    
fromVtyKey (Yi.Vty.KPrtScr  ) = Yi.Event.KPrtScr   
fromVtyKey (Yi.Vty.KPause   ) = Yi.Event.KPause    
fromVtyKey (Yi.Vty.KASCII c ) = Yi.Event.KASCII c  
fromVtyKey (Yi.Vty.KBS      ) = Yi.Event.KBS       
fromVtyKey (Yi.Vty.KIns     ) = Yi.Event.KIns      
fromVtyKey (Yi.Vty.KHome    ) = Yi.Event.KHome     
fromVtyKey (Yi.Vty.KPageUp  ) = Yi.Event.KPageUp   
fromVtyKey (Yi.Vty.KDel     ) = Yi.Event.KDel      
fromVtyKey (Yi.Vty.KEnd     ) = Yi.Event.KEnd      
fromVtyKey (Yi.Vty.KPageDown) = Yi.Event.KPageDown 
fromVtyKey (Yi.Vty.KNP5     ) = Yi.Event.KNP5      
fromVtyKey (Yi.Vty.KUp      ) = Yi.Event.KUp       
fromVtyKey (Yi.Vty.KMenu    ) = Yi.Event.KMenu     
fromVtyKey (Yi.Vty.KLeft    ) = Yi.Event.KLeft     
fromVtyKey (Yi.Vty.KDown    ) = Yi.Event.KDown     
fromVtyKey (Yi.Vty.KRight   ) = Yi.Event.KRight    
fromVtyKey (Yi.Vty.KEnter   ) = Yi.Event.KEnter    

fromVtyMod :: Yi.Vty.Modifier -> Yi.Event.Modifier
fromVtyMod Yi.Vty.MShift = Yi.Event.MShift
fromVtyMod Yi.Vty.MCtrl  = Yi.Event.MCtrl
fromVtyMod Yi.Vty.MMeta  = Yi.Event.MMeta
fromVtyMod Yi.Vty.MAlt   = Yi.Event.MMeta

-- | Redraw the entire terminal from the UI state
--
-- Two points remain: horizontal scrolling, and tab handling.
--
refresh :: UI -> EditorM ()
refresh ui = do
  lift $ logPutStrLn "refreshing screen."
  updateWindows ui
  ws <- liftIO $ readIORef (windows ui)
  let w = WS.current ws
  withEditor0 $ \e -> do
    let wImages = map picture (WS.contents ws)
    cmd <- readIORef (cmdline ui)
    (_yss,xss) <- readIORef (scrsize ui)
    Yi.Vty.update (vty $ ui) 
      pic {pImage = vertcat wImages <-> withStyle (window $ uistyle e) (take xss $ cmd ++ repeat ' '),
           pCursor = let (y,x) = cursor w in
                     Cursor x (y + (sum $ map height $ takeWhile (/= w) $ (WS.contents ws)))}
                       -- calculate origin of focused window
                       -- sum of heights of windows above this one on screen.
                       -- needs to be shifted 'x' by the width of the tabs on this line
  return ()

updateWindows :: UI -> EditorM ()
updateWindows ui = do
  ws0 <- liftIO $ readIORef (windows ui)
  WS.debug "Updating windows" ws0
  e <- (liftIO . readIORef) =<< ask
  ws <- liftIO $ T.mapM (\w -> drawWindow e (w == WS.current ws0) (uistyle e) w) ws0
  liftIO $ logPutStrLn "Windows updated!"
  liftIO $ writeIORef (windows ui) ws

showPoint :: Editor -> Window -> IO Window 
showPoint e w = do
  logPutStrLn $ "showPoint " ++ show w
  let b = findBufferWith e (bufkey w)          
  (result, []) <- runBuffer b $ 
            do ln <- curLn
               let gap = min (ln-1) ((height w) `div` 2)
                   topln = ln - gap
               i <- indexOfSolAbove gap
               return w {toslineno = topln,
                         tospnt = i}
  return result

-- | redraw a window
doDrawWindow :: Editor -> Bool -> UIStyle -> Window -> IO Window
doDrawWindow e focused sty win = do
    let b = findBufferWith e (bufkey win)
        w = width win
        h = height win
        m = mode win
        off = if m then 1 else 0
        h' = h - off
        wsty = styleToAttr (window sty)
        selsty = styleToAttr (selected sty)
        eofsty = eof sty
    (markPoint, []) <- runBuffer b (getMarkPointB =<< getSelectionMarkB)
    (point, []) <- runBuffer b pointB
    bufData <- nelemsBIH (rawbuf b) (w*h') (tospnt win) -- read enough chars from the buffer.
    let prompt = if isMini win then name b else ""

    let (rendered,bos,cur) = drawText h' w 
                                (tospnt win - length prompt) 
                                point markPoint 
                                selsty wsty 
                                (zip prompt (repeat wsty) ++ bufData ++ [(' ',attr)])
                             -- we always add one character which can be used to position the cursor at the end of file
                                                                                                 
    (modeLine0, []) <- runBuffer b getModeLine
    let modeLine = if m then Just modeLine0 else Nothing
    let modeLines = map (withStyle (modeStyle sty) . take w . (++ repeat ' ')) $ maybeToList $ modeLine
        modeStyle = if focused then modeline_focused else modeline        
        filler = take w (windowfill e : repeat ' ')
    
    return win { picture = vertcat (take h' (rendered ++ repeat (withStyle eofsty filler)) ++ modeLines),
                 cursor = cur,
                 bospnt = bos }
    
-- | Draw a window
-- TODO: horizontal scrolling.
drawWindow :: Editor
           -> Bool
           -> UIStyle
           -> Window
           -> IO Window

drawWindow e focused sty win = do
    let b = findBufferWith e (bufkey win)
    (point, []) <- runBuffer b pointB
    (if tospnt win <= point && point <= bospnt win then return win else showPoint e win) >>= doDrawWindow e focused sty   


-- | Renders text in a rectangle.
-- Also returns a finite map from buffer offsets to their position on the screen.
drawText :: Int -> Int -> Point -> Point -> Point -> Attr -> Attr -> [(Char,Attr)] -> ([Image], Point, (Int,Int))
drawText h w topPoint point markPoint selsty wsty bufData 
    | h == 0 || w == 0 = ([], topPoint, (0,0))
    | otherwise        = (rendered_lines, bottomPoint, pntpos)
  where [startSelect, stopSelect] = sort [markPoint,point]

        -- | Remember the point of each char
        annotateWithPoint text = zipWith (\(c,a) p -> (c,(a,p))) text [topPoint..]  

        lns0 = take h $ concatMap (wrapLine w) $ map (concatMap expandGraphic) $ lines' $ annotateWithPoint $ bufData

        bottomPoint = case lns0 of 
                        [] -> topPoint 
                        _ -> snd $ snd $ last $ last $ lns0

        pntpos = case [(y,x) | (y,l) <- zip [0..] lns0, (x,(_char,(_attr,p))) <- zip [0..] l, p == point] of
                   [] -> (0,0)
                   (pp:_) -> pp

        rendered_lines = map fillColorLine $ lns0 -- fill lines with blanks, so the selection looks ok.
        colorChar (c, (a, x)) = renderChar (pointStyle x a) c
        pointStyle x a = if startSelect < x && x <= stopSelect && selsty /= wsty then selsty else a

        fillColorLine [] = renderHFill attr ' ' w
        fillColorLine l = horzcat (map colorChar l) <|> renderHFill (pointStyle x a) ' ' (w - length l)
            where (_,(a,x)) = last l

        -- | Cut a string in lines separated by a '\n' char. Note
        -- that we add a blank character where the \n was, so the
        -- cursor can be positioned there.

        lines' :: [(Char,a)] -> [[(Char,a)]]
        lines' [] =  []
        lines' s  =  let (l, s') = break ((== '\n') . fst) s in case s' of
                                                                  [] -> [l]
                                                                  ((_,x):s'') -> (l++[(' ',x)]) : lines' s''

        wrapLine :: Int -> [x] -> [[x]]
        wrapLine _ [] = []
        wrapLine n l = let (x,rest) = splitAt n l in x : wrapLine n rest
                                      
        expandGraphic (c,p) | ord c < 32 = [('^',p),(chr (ord c + 64),p)]
                            | ord c < 128 = [(c,p)]
                            | otherwise = zip ('\\':show (ord c)) (repeat p)
                                            


-- TODO: The above will actually require a bit of work, in order to handle tabs.

withStyle :: Style -> String -> Image
withStyle sty str = renderBS (styleToAttr sty) (B.pack str)


------------------------------------------------------------------------
-- | Window manipulation

-- | Create a new window onto this buffer.
newWindow :: Bool -> FBuffer -> UI -> EditorM Window
newWindow mini b ui = do 
  win <- liftIO $ emptyWindow mini b (1,1)
  liftIO $ modifyIORef (windows ui) (turnOnML . WS.add win)
  liftIO $ logPutStrLn $ "created #" ++ show win
  doResizeAll ui
  ws <- liftIO (readIORef (windows ui))
  return $ WS.current ws

-- ---------------------------------------------------------------------
-- | Grow the given window, and pick another to shrink
-- grow and shrink compliment each other, they could be refactored.
--
enlargeWindow :: Window -> UI -> EditorM ()
enlargeWindow _ ui = return ()
-- enlargeWindow (Just win) ui = modifyEditor_ $ \e -> do
--     let wls      = (M.elems . windows) e
--     (maxy,x) <- readIORef $ scrsize $ ui
-- 
--     -- can't resize if only window on screen, or if no room left
--     if length wls == 1 || height win >= maxy - (2*length wls-1)
--         then return e else do
--     case elemIndex win wls of
--         Nothing -> error "Editor.Window: window not found"
--         Just i  -> -- else pick next window up to shrink
--             case getWinWithHeight wls i 1 (> 2) of
--                 Nothing -> return e    -- give up
--                 Just winnext -> do {
--     ;let win'     = resize (height win + 1)     x win
--     ;let winnext' = resize (height winnext -1)  x winnext
--     ;return $ e { windows = (M.insert (key winnext') winnext' $
--                               M.insert (key win') win' $ windows e) }
--     }
-- 

-- | shrink given window (just grow another)
shrinkWindow :: Window -> UI -> EditorM ()
shrinkWindow _ ui = return ()
-- shrinkWindow (Just win) ui = modifyEditor_ $ \e -> do
--     let wls      = (M.elems . windows) e
--     (maxy,x) <- readIORef $ scrsize $ ui
--     -- can't resize if only window on screen, or if no room left
--     if length wls == 1 || height win <= 3 -- rem..
--         then return e else do
--     case elemIndex win wls of
--         Nothing -> error "Editor.Window: window not found"
--         Just i  -> -- else pick a window that could be grown
--             case getWinWithHeight wls i 1 (< (maxy - (2 * length wls))) of
--                 Nothing -> return e    -- give up
--                 Just winnext -> do {
--     ;let win'     = resize (height win - 1)      x win
--     ;let winnext' = resize (height winnext + 1)  x winnext
--     ;return $ e { windows = (M.insert (key winnext') winnext' $
--                               M.insert (key win') win' $ windows e) }
--     }
-- 

-- | find a window, starting at offset @i + n@, whose height satisifies pred
--
getWinWithHeight :: [Window] -> Int -> Int -> (Int -> Bool) -> Maybe Window
getWinWithHeight wls i n p
   | n > length wls = Nothing
   | otherwise
   = let w = wls !! ((abs (i - n)) `mod` (length wls))
     in if p (height w)
                then Just w
                else getWinWithHeight wls i (n+1) p

--
-- | Delete a window. Note that the buffer that was connected to this
-- window is still open.
--
deleteWindow :: Window -> UI -> EditorM ()
deleteWindow win ui = do 
  liftIO $ modifyIORef (windows ui) (WS.delete win)
  doResizeAll ui

------------------------------------------------------------------------

-- | Reset the heights and widths of all the windows;
-- refresh the display.
refreshAll :: UI -> EditorM ()
refreshAll ui = do 
  doResizeAll ui
  refresh ui

-- | Schedule a refresh of the UI.
scheduleRefresh :: UI -> EditorM ()
scheduleRefresh ui = do
  modifyEditor_ $ \e -> return e {editorUpdates = []}
  lift $ scheduleRefresh' ui

prepareAction :: UI -> EditorM ()
prepareAction _ = return ()


scheduleRefresh' :: UI -> IO ()
scheduleRefresh' tui = tryPutMVar (uiRefresh tui) () >> return ()

-- | Reset the heights and widths of all the windows
doResizeAll :: UI -> EditorM ()
doResizeAll i = liftIO $ do 
  ws <- readIORef (windows i) 
  (h,w) <- readIORef $ scrsize i
  let (mwls, wls) = partition isMini $ WS.contents ws
      (y,r) = getY (h - length mwls) (length wls) 
      mwls' = map (doresize w 1) mwls
      wls' = case wls of
               [] -> []
               (w0:ws) -> doresize w (y+r-1) w0 : map (doresize w y) ws
      result = WS.WindowSet (mwls' ++ wls')
  writeIORef (windows i) result
  WS.debug "After resize: " result
                     
    where doresize x y win = resize y x win

-- | Turn on modelines of all windows
turnOnML :: WS.WindowSet Window -> WS.WindowSet Window
turnOnML = fmap $ \w -> w { mode = not (isMini w) }

-- | Has the frame enough room for an extra window.
hasRoomForExtraWindow :: UI -> EditorM Bool
hasRoomForExtraWindow ui = do
    ws <- liftIO (readIORef (windows ui))
    (y,_) <- screenSize ui 
    let (sy,r) = getY y (WS.size ws)
    return $ sy + r > 4  -- min window size

-- | Calculate window heights, given all the windows and current height.
-- Does not take into account modelines
getY :: Int -> Int -> (Int,Int)
getY screenHeight 0               = (screenHeight, 0)
getY screenHeight numberOfWindows = screenHeight `quotRem` numberOfWindows

setCmdLine :: String -> UI -> IO ()
setCmdLine s i = do 
  writeIORef (cmdline i) s
                
-- | Display the given buffer in the given window.
setWindowBuffer :: FBuffer -> Window -> UI -> EditorM ()
setWindowBuffer b w ui = do
    lift $ logPutStrLn $ "Setting buffer for " ++ show w ++ ": " ++ show b
    w'' <- do
                     w' <- lift $ emptyWindow False b (height w, width w)
                     return $ w' { key = key w, mode = mode w } 
                     -- reuse the window's key (so it ends in the same place on the screen)
    liftIO $ modifyIORef (windows ui) (WS.update w'')
    -- WS.debug "After setbuffer" =<< readRef windows

--
-- | Set current window
-- !! reset the buffer point from the window point
--
-- Factor in shift focus.
--
setWindow :: Window -> UI -> EditorM ()
setWindow w ui = do
  setBuffer (bufkey w)
  liftIO $ modifyIORef (windows ui) (WS.setFocus w)
  --  WS.debug "After focus" ws


withWindow0 :: (Window -> a) -> UI -> IO a
withWindow0 f ui = do
  ws <- readIORef (windows ui)
  return (f $ WS.current ws)

getWindows :: MonadIO m => UI -> m (WS.WindowSet Window)
getWindows ui = liftIO $ readIORef $ windows ui

getWindow :: MonadIO m => UI -> m Window
getWindow ui = do
  ws <- getWindows ui
  return (WS.current ws)
