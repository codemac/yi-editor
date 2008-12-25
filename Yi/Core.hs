{-# LANGUAGE ScopedTypeVariables, RecursiveDo, Rank2Types #-}

-- Copyright (c) Tuomo Valkonen 2004.
-- Copyright (c) Don Stewart 2004-5. http://www.cse.unsw.edu.au/~dons
-- Copyright (c) Jean-Philippe Bernardy 2007-8 

-- | The core actions of yi. This module is the link between the editor
-- and the UI. Key bindings, and libraries should manipulate Yi through
-- the interface defined here.

module Yi.Core 
  ( module Yi.Dynamic
    -- * Keymap
  , module Yi.Keymap

  , module Yi.Prelude
  , module Yi.Editor
  , module Yi.Buffer
  , module Yi.Keymap.Keys

  -- * Construction and destruction
  , startEditor         
  , quitEditor          -- :: YiM ()

  , getAllNamesInScope

  , refreshEditor       -- :: YiM ()
  , suspendEditor       -- :: YiM ()
  , userForceRefresh  

  -- * Global editor actions
  , msgEditor           -- :: String -> YiM ()
  , errorEditor         -- :: String -> YiM ()
  , closeWindow         -- :: YiM ()

  -- * Interacting with external commands
  , runProcessWithInput          -- :: String -> String -> YiM String
  , startSubprocess                 -- :: FilePath -> [String] -> YiM ()
  , sendToProcess

  -- * Misc
  , runAction
  , withSyntax
  ) 
where

import Control.Concurrent
import Control.Monad (when, forever)
import Control.Monad.Error ()
import Control.Monad.Reader (runReaderT, ask, asks)
import Control.Monad.State (gets)
import Control.Monad.Trans
import Control.OldException
import Data.Foldable (mapM_)
import Data.List (intercalate, filter, zip)
import Data.Maybe
import Data.Time.Clock.POSIX
import Prelude (realToFrac)
import System.Exit
import System.FilePath
import System.IO (Handle, hWaitForInput, hPutStr)
import System.PosixCompat.Files
import System.Process ( getProcessExitCode, ProcessHandle )
import Yi.Buffer
import Yi.Config
import Yi.Dynamic
import Yi.Editor
import Yi.Keymap
import Yi.Keymap.Keys
import Yi.KillRing (krEndCmd)
import Yi.Monad
import Yi.Prelude
import Yi.Process ( popen, createSubprocess, readAvailable, SubprocessId, SubprocessInfo(..) )
import Yi.String
import Yi.Style (errorStyle)
import Yi.UI.Common as UI (UI)
import qualified Data.DelayList as DelayList
import qualified Data.Map as M
import qualified Yi.Editor as Editor
import qualified Yi.Interact as I
import qualified Yi.UI.Common as UI
import qualified Yi.WindowSet as WS

-- | Make an action suitable for an interactive run.
-- UI will be refreshed.
interactive :: [Action] -> YiM ()
interactive action = do
  evs <- withEditor $ getA pendingEventsA
  logPutStrLn $ ">>> interactively" ++ showEvs evs
  prepAction <- withUI UI.prepareAction
  withEditor $ do prepAction
                  modA buffersA (fmap $  undosA ^: addChangeU InteractivePoint)
  mapM_ runAction action
  withEditor $ modA killringA krEndCmd
  refreshEditor
  logPutStrLn "<<<"
  return ()

-- ---------------------------------------------------------------------
-- | Start up the editor, setting any state with the user preferences
-- and file names passed in, and turning on the UI
--
startEditor :: Config -> Maybe Editor -> IO ()
startEditor cfg st = do
    let uiStart = startFrontEnd cfg

    logPutStrLn "Starting Core"

    -- restore the old state
    let initEditor = maybe emptyEditor id st
    -- Setting up the 1st window is a bit tricky because most functions assume there exists a "current window"
    newSt <- newMVar $ YiVar initEditor [] 1 M.empty
    (ui, runYi) <- mdo let handler exception = runYi $ (errorEditor (show exception) >> refreshEditor)
                           inF  ev  = handle handler (runYi (dispatch ev))
                           outF acts = handle handler (runYi (interactive acts))
                       ui <- uiStart cfg inF outF initEditor
                       let runYi f = runReaderT (runYiM f) yi
                           yi = Yi ui inF outF cfg newSt 
                       return (ui, runYi)
  
    runYi $ do

      when (isNothing st) $ do -- process options if booting for the first time
        postActions $ startActions cfg
      withEditor $ modA buffersA (fmap (recoverMode (modeTable cfg)))

    runYi refreshEditor

    UI.main ui -- transfer control to UI

recoverMode :: [AnyMode] -> FBuffer -> FBuffer
recoverMode tbl buffer  = case fromMaybe (AnyMode emptyMode) (find (\(AnyMode m) -> modeName m == oldName) tbl) of
    AnyMode m -> setMode0 m buffer
  where oldName = case buffer of FBuffer {bmode = m} -> modeName m

postActions :: [Action] -> YiM ()
postActions actions = do yi <- ask; liftIO $ output yi actions

-- | Process an event by advancing the current keymap automaton an
-- execing the generated actions
dispatch :: Event -> YiM ()
dispatch ev =
    do yi <- ask
       entryEvs <- withEditor $ getA pendingEventsA
       logPutStrLn $ "pending events: " ++ showEvs entryEvs
       (userActions,_p') <- withBuffer $ do
         keymap <- gets (withMode0 modeKeymap)
         p0 <- getA keymapProcessA
         let defKm = defaultKm $ yiConfig $ yi
         let freshP = I.mkAutomaton $ forever $ keymap $ defKm
             -- Note the use of "forever": this has quite subtle implications, as it means that
             -- failures in one iteration can yield to jump to the next iteration seamlessly.
             -- eg. in emacs keybinding, failures in incremental search, like <left>, will "exit"
             -- incremental search and immediately move to the left.
             p = case I.computeState p0 of
                   I.Dead  -> freshP
                   _      -> p0
             (actions, p') = I.processOneEvent p ev
             state = I.computeState p'
             ambiguous = case state of 
                 I.Ambiguous _ -> True
                 _ -> False
         putA keymapProcessA (if ambiguous then freshP else p')
         let actions0 = case state of 
                          I.Dead -> [makeAction $ do
                                         evs <- getA pendingEventsA
                                         printMsg ("Unrecognized input: " ++ showEvs (evs ++ [ev]))]
                          _ -> actions
             actions1 = if ambiguous 
                          then [makeAction $ printMsg "Keymap was in an ambiguous state! Resetting it."]
                          else []
         return (actions0 ++ actions1,p')
       -- logPutStrLn $ "Processing: " ++ show ev
       -- logPutStrLn $ "Actions posted:" ++ show userActions
       -- logPutStrLn $ "New automation: " ++ show _p'
       let decay, pendingFeedback :: EditorM ()
           decay = modA statusLinesA (DelayList.decrease 1)
           pendingFeedback = do modA pendingEventsA (++ [ev])
                                if null userActions
                                    then printMsg . showEvs =<< getA pendingEventsA
                                    else putA pendingEventsA []
       postActions $ [makeAction decay] ++ userActions ++ [makeAction pendingFeedback]

showEvs = intercalate " " . fmap prettyEvent
showEvs :: [Event] -> String

-- ---------------------------------------------------------------------
-- Meta operations

-- | Quit.
quitEditor :: YiM ()
quitEditor = withUI UI.end

-- | Redraw
refreshEditor :: YiM ()
refreshEditor = do 
    yi <- ask
    io $ modifyMVar_ (yiVar yi) $ \var -> do
        let e0 = yiEditor var 
            touchedBuffers = [(b,fname) | b <- bufferSet e0, Right fname <- [b ^.identA], not $ null $ b ^. pendingUpdatesA]

        modTimes <- mapM fileModTime (fmap snd touchedBuffers)
        let externallyTouchedBuffers = [b | ((b,fname),time) <- zip touchedBuffers modTimes, b ^. lastSyncTimeA < time]
            e1 = buffersA ^: (fmap (clearSyntax . clearHighlight)) $ e0
            e2 = buffersA ^: (fmap clearUpdates) $ e1
            msg = (1, ("Careful: buffers you are currently editing are modified by another process!", errorStyle))
            e1' = if not $ null $ externallyTouchedBuffers 
               then (statusLinesA ^: DelayList.insert msg) e1
               else e1
        UI.refresh (yiUi yi) e1'
        return var {yiEditor = e2}
  where 
    clearUpdates fb = pendingUpdatesA ^= [] $ fb
    clearHighlight fb =
      -- if there were updates, then hide the selection.
      let h = getVal highlightSelectionA fb
          us = getVal pendingUpdatesA fb
      in highlightSelectionA ^= (h && null us) $ fb
    isRight (Right _) = True
    isRight _ = False
    fileModTime f = posixSecondsToUTCTime . realToFrac . modificationTime <$> getFileStatus f
          

-- | Suspend the program
suspendEditor :: YiM ()
suspendEditor = withUI UI.suspend

------------------------------------------------------------------------

------------------------------------------------------------------------
-- | Pipe a string through an external command, returning the stdout
-- chomp any trailing newline (is this desirable?)
--
-- Todo: varients with marks?
--
runProcessWithInput :: String -> String -> YiM String
runProcessWithInput cmd inp = do
    let (f:args) = split " " cmd
    (out,_err,_) <- liftIO $ popen f args (Just inp)
    return (chomp "\n" out)


------------------------------------------------------------------------

-- | Same as msgEditor, but do nothing instead of printing @()@
msgEditor' :: String -> YiM ()
msgEditor' "()" = return ()
msgEditor' s = msgEditor s

runAction :: Action -> YiM ()
runAction (YiA act) = do
  act >>= msgEditor' . show
  return ()
runAction (EditorA act) = do
  withEditor act >>= msgEditor' . show
  return ()
runAction (BufferA act) = do
  withBuffer act >>= msgEditor' . show
  return ()

msgEditor :: String -> YiM ()
msgEditor = withEditor . printMsg

-- | Show an error on the status line and log it.
errorEditor :: String -> YiM ()
errorEditor s = do withEditor $ printStatus ("error: " ++ s, errorStyle)
                   logPutStrLn $ "errorEditor: " ++ s

-- | Close the current window.
-- If this is the last window open, quit the program.
-- FIXME: call quitEditor when there are no other window in the interactive command.
closeWindow :: YiM ()
closeWindow = do
    winCount <- withEditor $ getsA windowsA WS.size
    tabCount <- withEditor $ getsA tabsA WS.size
    when (winCount == 1 && tabCount == 1) quitEditor
    withEditor $ tryCloseE

  
getAllNamesInScope :: YiM [String]
getAllNamesInScope = do 
  acts <- asks (publishedActions . yiConfig)
  return (M.keys acts)

-- | Start a subprocess with the given command and arguments.
startSubprocess :: FilePath -> [String] -> (Either Exception ExitCode -> YiM x) -> YiM BufferRef
startSubprocess cmd args onExit = do
    yi <- ask
    io $ modifyMVar (yiVar yi) $ \var -> do        
        let (e', bufref) = runEditor 
                              (yiConfig yi) 
                              (printMsg ("Launched process: " ++ cmd) >> newBufferE (Left bufferName) (fromString ""))
                              (yiEditor var)
            procid = yiSubprocessIdSupply var + 1
        procinfo <- createSubprocess cmd args bufref
        startSubprocessWatchers procid procinfo yi onExit
        return (var {yiEditor = e', 
                     yiSubprocessIdSupply = procid,
                     yiSubprocesses = M.insert procid procinfo (yiSubprocesses var)
                    }, bufref)
  where bufferName = "output from " ++ cmd ++ " " ++ show args

startSubprocessWatchers :: SubprocessId -> SubprocessInfo -> Yi -> (Either Exception ExitCode -> YiM x) -> IO ()
startSubprocessWatchers procid procinfo yi onExit = do
    mapM_ forkOS ([pipeToBuffer (hErr procinfo) (send . append True) | separateStdErr procinfo] ++
                 [pipeToBuffer (hOut procinfo) (send . append False),
                  waitForExit (procHandle procinfo) >>= reportExit])
  where send a = output yi [makeAction a]
        append :: Bool -> String -> YiM ()
        append atMark s = withEditor $ appendToBuffer atMark (bufRef procinfo) s
        reportExit ec = send $ do append True ("Process exited with " ++ show ec)
                                  removeSubprocess procid
                                  onExit ec
                                  return ()

removeSubprocess :: SubprocessId -> YiM ()
removeSubprocess procid = modifiesRef yiVar (\v -> v {yiSubprocesses = M.delete procid $ yiSubprocesses v})

appendToBuffer :: Bool -> BufferRef -> String -> EditorM ()
appendToBuffer atErr bufref s = withGivenBuffer0 bufref $ do
    -- We make sure stdout is always after stderr. This ensures that the output of the
    -- two pipe do not get interleaved. More importantly, GHCi prompt should always
    -- come after the error messages.
    me <- getMarkB (Just "StdERR")
    mo <- getMarkB (Just "StdOUT")
    let mms = if atErr then [mo,me] else [mo]
    forM_ mms (flip modifyMarkB (\v -> v {markGravity = Forward}))
    insertNAt s =<< getMarkPointB (if atErr then me else mo)
    forM_ mms (flip modifyMarkB (\v -> v {markGravity = Backward}))

sendToProcess :: BufferRef -> String -> YiM ()
sendToProcess bufref s = do
    yi <- ask
    Just subProcessInfo <- find ((== bufref) . bufRef) . yiSubprocesses <$> readRef (yiVar yi)
    io $ hPutStr (hIn subProcessInfo) s

pipeToBuffer :: Handle -> (String -> IO ()) -> IO ()
pipeToBuffer h append = 
  handle (const $ return ()) $ forever $ (hWaitForInput h (-1) >> readAvailable h >>= append)


waitForExit :: ProcessHandle -> IO (Either Exception ExitCode)
waitForExit ph = 
    handle (\e -> return (Left e)) $ do 
      mec <- getProcessExitCode ph
      case mec of
          Nothing -> threadDelay (500*1000) >> waitForExit ph
          Just ec -> return (Right ec)

withSyntax :: (Show x, YiAction a x) => (forall syntax. Mode syntax -> syntax -> a) -> YiM ()
withSyntax f = do
            b <- withEditor Editor.getBuffer
            act <- withGivenBuffer b $ gets (withSyntax0 f)
            runAction $ makeAction $ act

userForceRefresh :: YiM ()
userForceRefresh = withUI UI.userForceRefresh
