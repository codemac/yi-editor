--
-- Copyright (C) 2004-5 Don Stewart - http://www.cse.unsw.edu.au/~dons
--
--
-- Derived from: riot/UI.hs
--
--      Copyright (c) Tuomo Valkonen 2004.
--
-- Released under the same license.
--

-- | This module defines a user interface implemented using ncurses.

module Yi.UI.Vty (start) where

import Prelude hiding (error, concatMap, sum, mapM, sequence)

import Control.Concurrent
import Control.Concurrent.Chan
import Control.Exception
import Control.Monad (forever)
import Control.Monad.State (runState, State, gets, modify, get, put)
import Control.Monad.Trans (liftIO, MonadIO)
import Control.Arrow (second)
import Data.Char (ord,chr)
import Data.Foldable
import Data.IORef
import Data.List (partition)
import Data.Maybe
import Data.Traversable
import System.Exit
import System.Posix.Signals         ( raiseSignal, sigTSTP )
import Yi.Buffer
import Yi.Buffer.Implementation
import Yi.Buffer.Region
import Yi.Buffer.HighLevel
import Yi.Debug
import Yi.Editor
import Yi.Event
import Yi.Monad
import Yi.Style
import Yi.Vty hiding (def, black, red, green, yellow, blue, magenta, cyan, white)
import Yi.WindowSet as WS
import qualified Data.ByteString.Char8 as B
import qualified Yi.UI.Common as Common
import Yi.Window
------------------------------------------------------------------------

data Rendered = 
    Rendered {
              picture :: !Image           -- ^ the picture currently displayed.
             ,cursor  :: !(Maybe (Int,Int)) -- ^ cursor point on the above
             }




data UI = UI { 
              vty       :: Vty              -- ^ Vty
             ,scrsize   :: IORef (Int,Int)  -- ^ screen size
             ,uiThread  :: ThreadId
             ,uiRefresh :: MVar ()
             ,uiEditor  :: IORef Editor
             }
mkUI :: UI -> Common.UI
mkUI ui = Common.UI 
  {
   Common.main           = main ui,
   Common.end            = end ui,
   Common.suspend        = raiseSignal sigTSTP,
   Common.refresh        = scheduleRefresh ui,
   Common.prepareAction  = prepareAction ui
  }


-- | Initialise the ui
start :: Chan Yi.Event.Event -> Chan action ->
         Editor -> (EditorM () -> action) -> 
         IO Common.UI
start ch _outCh editor _runEd = do
  liftIO $ do 
          v <- mkVty
          (x0,y0) <- Yi.Vty.getSize v
          sz <- newIORef (y0,x0)
          -- fork input-reading thread. important to block *thread* on getKey
          -- otherwise all threads will block waiting for input
          t <- myThreadId
          tuiRefresh <- newEmptyMVar
          editorRef <- newIORef editor
          let result = UI v sz t tuiRefresh editorRef
              -- | Action to read characters into a channel
              getcLoop = forever $ getKey >>= writeChan ch

              -- | Read a key. UIs need to define a method for getting events.
              getKey = do 
                event <- getEvent v
                case event of 
                  (EvResize x y) -> do logPutStrLn $ "UI: EvResize: " ++ show (x,y)
                                       writeIORef sz (y,x) >> readRef (uiEditor result) >>= refresh result >> getKey
                  _ -> return (fromVtyEvent event)
          forkIO $ getcLoop
          return (mkUI result)
        

main :: UI -> IO ()
main ui = do
  let
      -- | When the editor state isn't being modified, refresh, then wait for
      -- it to be modified again. 
      refreshLoop :: IO ()
      refreshLoop = forever $ do 
                      logPutStrLn "waiting for refresh"
                      takeMVar (uiRefresh ui)
                      handleJust ioErrors (\except -> do 
                                             logPutStrLn "refresh crashed with IO Error"
                                             logError $ show $ except)
                                     (readRef (uiEditor ui) >>= refresh ui >> return ())
  readRef (uiEditor ui) >>= scheduleRefresh ui
  logPutStrLn "refreshLoop started"
  refreshLoop
  

-- | Clean up and go home
end :: UI -> IO ()
end i = do  
  Yi.Vty.shutdown (vty i)
  throwTo (uiThread i) (ExitException ExitSuccess)

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

prepareAction :: UI -> IO (EditorM ())
prepareAction ui = do
  (yss,xss) <- readRef (scrsize ui)
  return $ do
    e <- get
    modifyWindows $ \ws0 ->      
      let ws1 = computeHeights yss ws0
          zzz = fmap (scrollAndRenderWindow e (uistyle e) xss) (WS.withFocus ws1)
          -- note that the rendering won't actually be performed because of laziness.
      in  (fmap fst zzz)


-- | Redraw the entire terminal from the UI.
-- Among others, this re-computes the heights and widths of all the windows.

-- Two points remain: horizontal scrolling, and tab handling.
refresh :: UI -> Editor -> IO (WS.WindowSet Window)
refresh ui e = do
  let ws0 = windows e
  logPutStrLn "refreshing screen."
  (yss,xss) <- readRef (scrsize ui)
  let ws1 = computeHeights yss ws0
      cmd = statusLine e
      zzz = fmap (scrollAndRenderWindow e (uistyle e) xss) (WS.withFocus ws1)

  let startXs = scanrT (+) 0 (fmap height ws1)
      wImages = fmap picture $ fmap snd $ zzz
     
  WS.debug "Drawing: " ws1
  logPutStrLn $ "startXs: " ++ show startXs
  Yi.Vty.update (vty $ ui) 
      pic {pImage = vertcat (toList wImages) <-> withStyle (window $ uistyle e) (take xss $ cmd ++ repeat ' '),
           pCursor = case cursor (snd $ WS.current zzz) of
                       Just (y,x) -> Cursor x (y + WS.current startXs)
                       Nothing -> NoCursor
                       -- This can happen if the user resizes the window. 
                       -- Not really nice, but upon the next refresh the cursor will show.
                       }

  return (fmap fst zzz)

scanrT :: (Int -> Int -> Int) -> Int -> WindowSet Int -> WindowSet Int
scanrT (+*+) k t = fst $ runState (mapM f t) k
    where f x = do s <- get
                   let s' = s +*+ x
                   put s'
                   return s
           

-- | Scrolls the window to show the point if needed
scrollAndRenderWindow :: Editor -> UIStyle -> Int -> (Window, Bool) -> (Window, Rendered)
scrollAndRenderWindow e sty width (win,hasFocus) = (win' {bospnt = bos}, rendered)
    where b = findBufferWith (bufkey win) e
          (point, _) = runBufferDummyWindow b pointB
          win' = if not hasFocus || pointInWindow point win then win else showPoint e win
          (rendered, bos) = drawWindow e sty hasFocus width win'

-- | return index of Sol on line @n@ above current line
indexOfSolAbove :: Int -> BufferM Int
indexOfSolAbove n = savingPointB $ do
    gotoLnFrom (negate n)
    pointB

showPoint :: Editor -> Window -> Window 
showPoint e w = result
  where b = findBufferWith (bufkey w) e
        (result, _) = runBufferDummyWindow b $ 
            do ln <- curLn
               let gap = min (ln-1) (height w `div` 2)
               i <- indexOfSolAbove gap
               return w {tospnt = i}

-- | Draw a window
-- TODO: horizontal scrolling.
drawWindow :: Editor -> UIStyle -> Bool -> Int -> Window -> (Rendered, Int)
drawWindow e sty focused w win = (Rendered { picture = pict,cursor = cur}, bos)
            
    where
        b = findBufferWith (bufkey win) e
        m = not (isMini win)
        off = if m then 1 else 0
        h' = height win - off
        wsty = styleToAttr (window sty)
        selsty = styleToAttr (selected sty)
        eofsty = eof sty
        (selreg, _) = runBufferDummyWindow b getSelectRegionB
        (point, _) = runBufferDummyWindow b pointB
        (bufData, _) = runBufferDummyWindow b (nelemsBH (w*h') (tospnt win)) -- read enough chars from the buffer.
        prompt = if isMini win then name b else ""

        (rendered,bos,cur) = drawText h' w
                                (tospnt win - length prompt) 
                                point selreg
                                selsty wsty 
                                (zip prompt (repeat wsty) ++ map (second styleToAttr) bufData ++ [(' ',attr)])
                             -- we always add one character which can be used to position the cursor at the end of file
                                                                                                 
        (modeLine0, _) = runBufferDummyWindow b getModeLine
        modeLine = if m then Just modeLine0 else Nothing
        modeLines = map (withStyle (modeStyle sty) . take w . (++ repeat ' ')) $ maybeToList $ modeLine
        modeStyle = if focused then modeline_focused else modeline        
        filler = take w (windowfill e : repeat ' ')
    
        pict = vertcat (take h' (rendered ++ repeat (withStyle eofsty filler)) ++ modeLines)
  
-- | Renders text in a rectangle.
-- This also returns 
-- * the index of the last character fitting in the rectangle
-- * the position of the Point in (x,y) coordinates, if in the window.
drawText :: Int    -- ^ The height of the part of the window we are in
         -> Int    -- ^ The width of the part of the window we are in
         -> Point  -- ^ The position of the first character to draw
         -> Point  -- ^ The position of the cursor
         -> Region -- ^ The selected region
         -> Attr   -- ^ The attribute with which to draw selected text
         -> Attr   -- ^ The attribute with which to draw the background
                   -- this is not used for drawing but only to compare
                   -- it against the selection attribute to avoid making
                   -- the selection invisible.
         -> [(Char,Attr)]  -- ^ The data to draw.
         -> ([Image], Point, Maybe (Int,Int))
drawText h w topPoint point selreg selsty wsty bufData
    | h == 0 || w == 0 = ([], topPoint, Nothing)
    | otherwise        = (rendered_lines, bottomPoint, pntpos)
  where 
  -- | Remember the point of each char
  annotateWithPoint text = zipWith (\(c,a) p -> (c,(a,p))) text [topPoint..]  

  lns0 = take h $ concatMap (wrapLine w) $ map (concatMap expandGraphic) $ lines' $ annotateWithPoint $ bufData

  bottomPoint = case lns0 of 
                 [] -> topPoint 
                 _ -> snd $ snd $ last $ last $ lns0

  pntpos = listToMaybe [(y,x) | (y,l) <- zip [0..] lns0, (x,(_char,(_attr,p))) <- zip [0..] l, p == point]

  -- fill lines with blanks, so the selection looks ok.
  rendered_lines = map fillColorLine lns0
  colorChar (c, (a, x)) = renderChar (pointStyle x a) c

  pointStyle :: Point -> Attr -> Attr
  pointStyle x a 
    | x == point          = a
    | x `inRegion` selreg 
      && selsty /= wsty   = selsty
    | otherwise           = a

  fillColorLine :: [(Char, (Attr, Point))] -> Image
  fillColorLine [] = renderHFill attr ' ' w
  fillColorLine l = horzcat (map colorChar l) 
                    <|>
                    renderHFill (pointStyle x a) ' ' (w - length l)
                    where (_,(a,x)) = last l

  -- | Cut a string in lines separated by a '\n' char. Note
  -- that we add a blank character where the \n was, so the
  -- cursor can be positioned there.

  lines' :: [(Char,a)] -> [[(Char,a)]]
  lines' [] =  []
  lines' s  = case s' of
                []          -> [l]
                ((_,x):s'') -> (l++[(' ',x)]) : lines' s''
              where
              (l, s') = break ((== '\n') . fst) s

  wrapLine :: Int -> [x] -> [[x]]
  wrapLine _ [] = []
  wrapLine n l = let (x,rest) = splitAt n l in x : wrapLine n rest
                                      
  expandGraphic (c,p) 
    | ord c < 32 = [('^',p),(chr (ord c + 64),p)]
    | ord c < 128 = [(c,p)]
    | otherwise = zip ('\\':show (ord c)) (repeat p)
                                            


-- TODO: The above will actually require a bit of work, in order to handle tabs.

withStyle :: Style -> String -> Image
withStyle sty str = renderBS (styleToAttr sty) (B.pack str)


------------------------------------------------------------------------


-- | Schedule a refresh of the UI.
scheduleRefresh :: UI -> Editor -> IO ()
scheduleRefresh ui e = do
  writeRef (uiEditor ui) e
  logPutStrLn "scheduleRefresh"
  tryPutMVar (uiRefresh ui) ()
  return ()
-- The non-blocking behviour was set up with this in mind: if the display
-- thread is not able to catch up with the editor updates (possible since
-- display is much more time consuming than simple editor operations),
-- then there will be fewer display refreshes. 

-- | Calculate window heights, given all the windows and current height.
-- (No specific code for modelines)
computeHeights :: Int -> WindowSet Window  -> WindowSet Window
computeHeights totalHeight ws = result
  where (mwls, wls) = partition isMini (toList ws)
        (y,r) = getY (totalHeight - length mwls) (length wls) 
        (result, _) = runState (Data.Traversable.mapM distribute ws) ((y+r-1) : repeat y)

distribute :: Window -> State [Int] Window
distribute win = case isMini win of
                 True -> return win {height = 1}
                 False -> do h <- gets head
                             modify tail
                             return win {height = h}

getY :: Int -> Int -> (Int,Int)
getY screenHeight 0               = (screenHeight, 0)
getY screenHeight numberOfWindows = screenHeight `quotRem` numberOfWindows

