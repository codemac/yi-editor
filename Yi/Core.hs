{-# LANGUAGE PatternSignatures #-}

-- Copyright (c) Tuomo Valkonen 2004.
-- Copyright (c) Don Stewart 2004-5. http://www.cse.unsw.edu.au/~dons

--
-- | The core actions of yi. This module is the link between the editor
-- and the UI. Key bindings, and libraries should manipulate Yi through
-- the interface defined here.

module Yi.Core (
                module Yi.Dynamic,
        -- * Keymap
        module Yi.Keymap,

        -- * Construction and destruction
        StartConfig    ( .. ), -- Must be passed as the first argument to 'startEditor'
        startEditor,         -- :: StartConfig -> Kernel -> Maybe Editor -> [YiM ()] -> IO ()
        quitEditor,          -- :: YiM ()

#ifdef DYNAMIC
        reconfigEditor,
        loadModule,
        unloadModule,
#endif
        reloadEditor,        -- :: YiM ()
        getAllNamesInScope,
        execEditorAction,

        refreshEditor,       -- :: YiM ()
        suspendEditor,       -- :: YiM ()

        -- * Global editor actions
        msgEditor,           -- :: String -> YiM ()
        errorEditor,         -- :: String -> YiM ()
        msgClr,        -- :: YiM ()

        -- * Window manipulation
        closeWindow,         -- :: YiM ()

        -- * Interacting with external commands
        runProcessWithInput,          -- :: String -> String -> YiM String

        -- * Misc
        changeKeymap,
        runAction
   ) where

import Prelude hiding (error, sequence_, mapM_, elem, concat, all)

import Yi.Debug
import Yi.Undo
import Yi.Buffer
import Yi.Dynamic
import Yi.String
import Yi.Process           ( popen )
import Yi.Editor
#ifdef DYNAMIC

#endif
import Yi.Event (eventToChar, Event)
import Yi.Keymap
import Yi.KillRing (krEndCmd)
import qualified Yi.Interact as I
import Yi.Monad
import Yi.Accessor
import qualified Yi.WindowSet as WS
import qualified Yi.Editor as Editor
import qualified Yi.UI.Common as UI
import Yi.UI.Common as UI (UI)

import Data.Maybe
import qualified Data.Map as M

import Data.IORef
import Data.Foldable

import System.FilePath

import Control.Monad (when, forever)
import Control.Monad.Reader (runReaderT, ask)
import Control.Monad.Trans
import Control.Monad.Error ()
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Chan
import Yi.Kernel

#ifdef DYNAMIC

import Data.List (notElem, delete)
import qualified ErrUtils
import qualified GHC
import qualified SrcLoc
import Outputable

#endif

-- | Make an action suitable for an interactive run.
-- UI will be refreshed.
interactive :: Action -> YiM ()
interactive action = do
  logPutStrLn ">>> interactively"
  prepAction <- withUI UI.prepareAction
  withEditor $ do prepAction
                  modifyAllA buffersA undosA (addUR InteractivePoint)
  runAction action
  withEditor $ modifyA killringA krEndCmd
  refreshEditor
  logPutStrLn "<<<"
  return ()

nilKeymap :: Keymap
nilKeymap = do c <- I.anyEvent
               write $ case eventToChar c of
                         'q' -> quitEditor
                         'r' -> reconfigEditor
                         'h' -> (configHelp >> return ())
                         _ -> errorEditor $ "Keymap not defined, type 'r' to reload config, 'q' to quit, 'h' for help."
    where configHelp = withEditor $ newBufferE "*configuration help*" $ unlines $
                         ["To get a standard reasonable keymap, you can run yi with either --as=vim or --as=emacs.",
                          "You can also create your own ~/.yi/YiConfig.hs file,",
                          "see http://haskell.org/haskellwiki/Yi#How_to_Configure_Yi for help on how to do that."]


data StartConfig = StartConfig { startFrontEnd   :: UI.UIBoot
                               , startConfigFile :: FilePath
                               }

-- ---------------------------------------------------------------------
-- | Start up the editor, setting any state with the user preferences
-- and file names passed in, and turning on the UI
--
startEditor :: StartConfig -> Kernel -> Maybe Editor -> [YiM ()] -> IO ()
startEditor startConfig kernel st commandLineActions = do
    let
#ifdef DYNAMIC
        yiConfigFile   = startConfigFile startConfig
#endif
        uiStart        = startFrontEnd startConfig

    logPutStrLn "Starting Core"

    -- restore the old state
    let initEditor = maybe emptyEditor id st
    newSt <- newIORef initEditor
    -- Setting up the 1st window is a bit tricky because most functions assume there exists a "current window"
    inCh <- newChan
    outCh :: Chan Action <- newChan
    ui <- uiStart inCh outCh initEditor makeAction
    startKm <- newIORef nilKeymap
    startModules <- newIORef ["Yi.Yi"] -- this module re-exports all useful stuff, so we want it loaded at all times.
    startThreads <- newIORef []
    keymaps <- newIORef M.empty
    let yi = Yi newSt ui startThreads inCh outCh startKm keymaps kernel startModules
        runYi f = runReaderT f yi

    runYi $ do

      withEditor $ newBufferE "*messages*" "" >> return ()

#ifdef DYNAMIC
      withKernel $ \k -> do
        dflags <- getSessionDynFlags k
        setSessionDynFlags k dflags { GHC.log_action = ghcErrorReporter yi }
      -- run user configuration
      loadModule yiConfigFile -- "YiConfig"
      runConfig
#endif

      when (isNothing st) $ do -- process options if booting for the first time
        sequence_ commandLineActions

    logPutStrLn "Starting event handler"
    let
        handler e = runYi $ errorEditor (show e)
        -- | The editor's input main loop.
        -- Read key strokes from the ui and dispatches them to the buffer with focus.
        eventLoop :: IO ()
        eventLoop = do
            let run = mapM_ (\ev -> runYi (dispatch ev)) =<< getChanContents inCh
            forever $ (handle handler run >> logPutStrLn "Dispatching loop ended")


        -- | The editor's output main loop.
        execLoop :: IO ()
        execLoop = do
            runYi refreshEditor
            let loop = sequence_ . map runYi . map interactive =<< getChanContents outCh
            forever $ (handle handler loop >> logPutStrLn "Execing loop ended")

    t1 <- forkIO eventLoop
    t2 <- forkIO execLoop
    runYi $ modifiesRef threads (\ts -> t1 : t2 : ts)

    UI.main ui -- transfer control to UI: GTK must run in the main thread, or else it's not happy.

postActions :: [Action] -> YiM ()
postActions actions = do yi <- ask; lift $ writeList2Chan (output yi) actions

-- | Process an event by advancing the current keymap automaton an
-- execing the generated actions
dispatch :: Event -> YiM ()
dispatch ev =
    do yi <- ask
       b <- withEditor getBuffer
       bkm <- getBufferKeymap b
       defKm <- readRef (defaultKeymap yi)
       let p0 = bufferKeymapProcess bkm
           freshP = I.mkAutomaton $ bufferKeymap bkm $ defKm
           p = case p0 of
                 I.End -> freshP
                 I.Fail -> freshP -- TODO: output error message about unhandled input
                 _ -> p0
           (actions, p') = I.processOneEvent p ev
           possibilities = I.possibleActions p'
           ambiguous = not (null possibilities) && all isJust possibilities
       logPutStrLn $ "Processing: " ++ show ev
       logPutStrLn $ "Actions posted:" ++ show actions
       logPutStrLn $ "New automation: " ++ show p'
       -- TODO: if no action is posted, accumulate the input and give feedback to the user.
       postActions actions
       when ambiguous $
            postActions [makeAction $ msgEditor "Keymap was in an ambiguous state! Resetting it."]
       modifiesRef bufferKeymaps (M.insert b bkm { bufferKeymapProcess = if ambiguous then freshP
                                                                         else p'})


changeKeymap :: Keymap -> YiM ()
changeKeymap km = do
  modifiesRef defaultKeymap (const km)
  bs <- withEditor getBuffers
  mapM_ (restartBufferThread . bkey) bs
  return ()

-- ---------------------------------------------------------------------
-- Meta operations

-- | Quit.
quitEditor :: YiM ()
quitEditor = withUI UI.end

#ifdef DYNAMIC
loadModules :: [String] -> YiM (Bool, [String])
loadModules modules = do
  withKernel $ \kernel -> do
    targets <- mapM (\m -> guessTarget kernel m Nothing) modules
    setTargets kernel targets
  -- lift $ rts_revertCAFs -- FIXME: GHCi does this; It currently has undesired effects on logging; investigate.
  logPutStrLn $ "Loading targets..."
  result <- withKernel loadAllTargets
  loaded <- withKernel setContextAfterLoad
  ok <- case result of
    GHC.Failed -> withOtherWindow (withEditor (switchToBufferE =<< getBufferWithName "*console*")) >> return False
    _ -> return True
  let newModules = map (moduleNameString . moduleName) loaded
  writesRef editorModules newModules
  logPutStrLn $ "loadModules: " ++ show modules ++ " -> " ++ show (ok, newModules)
  return (ok, newModules)

--foreign import ccall "revertCAFs" rts_revertCAFs  :: IO ()
        -- Make it "safe", just in case

tryLoadModules :: [String] -> YiM [String]
tryLoadModules [] = return []
tryLoadModules  modules = do
  (ok, newModules) <- loadModules modules
  if ok
    then return newModules
    else tryLoadModules (init modules)
    -- when failed, try to drop the most recently loaded module.
    -- We do this because GHC stops trying to load modules upon the 1st failing modules.
    -- This allows to load more modules if we ever try loading a wrong module.

-- | (Re)compile
reloadEditor :: YiM [String]
reloadEditor = tryLoadModules =<< readsRef editorModules
#endif
-- | Redraw
refreshEditor :: YiM ()
refreshEditor = do editor <- with yiEditor readRef
                   withUI $ flip UI.refresh editor
                   withEditor $ modifyAllA buffersA pendingUpdatesA (const [])

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
    (out,_err,_) <- lift $ popen f args (Just inp)
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
errorEditor s = do msgEditor ("error: " ++ s)
                   logPutStrLn $ "errorEditor: " ++ s

-- | Clear the message line at bottom of screen
msgClr :: YiM ()
msgClr = msgEditor ""

-- | Close the current window.
-- If this is the last window open, quit the program.
closeWindow :: YiM ()
closeWindow = do
    n <- withEditor $ withWindows WS.size
    when (n == 1) quitEditor
    withEditor $ tryCloseE

#ifdef DYNAMIC

-- | Recompile and reload the user's config files
reconfigEditor :: YiM ()
reconfigEditor = reloadEditor >> runConfig

runConfig :: YiM ()
runConfig = do
  loaded <- withKernel $ \kernel -> do
              let cfgMod = mkModuleName kernel "YiConfig"
              isLoaded kernel cfgMod
  if loaded
   then do result <- withKernel $ \kernel -> evalMono kernel "YiConfig.yiMain :: Yi.Yi.YiM ()"
           case result of
             Nothing -> errorEditor "Could not run YiConfig.yiMain :: Yi.Yi.YiM ()"
             Just x -> x
   else errorEditor "YiConfig not loaded"

loadModule :: String -> YiM [String]
loadModule modul = do
  logPutStrLn $ "loadModule: " ++ modul
  ms <- readsRef editorModules
  tryLoadModules (if Data.List.notElem modul ms then ms++[modul] else ms)

unloadModule :: String -> YiM [String]
unloadModule modul = do
  ms <- readsRef editorModules
  tryLoadModules $ delete modul ms

getAllNamesInScope :: YiM [String]
getAllNamesInScope = do
  withKernel $ \k -> do
      rdrNames <- getRdrNamesInScope k
      names <- getNamesInScope k
      return $ map (nameToString k) rdrNames ++ map (nameToString k) names

ghcErrorReporter :: Yi -> GHC.Severity -> SrcLoc.SrcSpan -> Outputable.PprStyle -> ErrUtils.Message -> IO ()
ghcErrorReporter yi severity srcSpan pprStyle message =
    -- the following is written in very bad style.
    flip runReaderT yi $ do
      e <- readEditor id
      let [b] = findBufferWithName "*console*" e
      withGivenBuffer b $ savingExcursionB $ do
        moveTo =<< getMarkPointB =<< getMarkB (Just "errorInsert")
        insertN msg
        insertN "\n"
    where msg = case severity of
                  GHC.SevInfo -> show (message pprStyle)
                  GHC.SevFatal -> show (message pprStyle)
                  _ -> show ((ErrUtils.mkLocMessage srcSpan message) pprStyle)


-- | Run a (dynamically specified) editor command.
execEditorAction :: String -> YiM ()
execEditorAction s = do
  ghcErrorHandler $ do
            result <- withKernel $ \kernel -> do
                               logPutStrLn $ "execing " ++ s
                               evalMono kernel ("makeAction (" ++ s ++ ") :: Yi.Yi.Action")
            case result of
              Left err -> errorEditor err
              Right x -> do runAction x
                            return ()

-- | Install some default exception handlers and run the inner computation.
ghcErrorHandler :: YiM () -> YiM ()
ghcErrorHandler inner = do
  flip catchDynE (\dyn -> do
                    case dyn of
                     GHC.PhaseFailed _ code -> errorEditor $ "Exitted with " ++ show code
                     GHC.Interrupted -> errorEditor $ "Interrupted!"
                     _ -> do errorEditor $ "GHC exeption: " ++ (show (dyn :: GHC.GhcException))

            ) $
            inner

withOtherWindow :: YiM () -> YiM ()
withOtherWindow f = do
  withEditor $ shiftOtherWindow
  f
  withEditor $ prevWinE

#else
reloadEditor, reconfigEditor :: YiM ()
reconfigEditor = msgEditor "reconfigEditor: Not supported"
reloadEditor = msgEditor "reloadEditor: Not supported"
execEditorAction :: t -> YiM ()
execEditorAction _ = msgEditor "execEditorAction: Not supported"

getAllNamesInScope :: YiM [String]
getAllNamesInScope = return []
#endif
