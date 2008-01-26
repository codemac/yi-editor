 module Yi.MiniBuffer (
        spawnMinibufferE, withMinibuffer
)where

import Yi.Core
import Yi.Debug
import Yi.Undo
import Yi.Buffer
import Yi.Window
import Yi.Buffer.HighLevel
import Yi.Dynamic
import Yi.String
import Yi.Process           ( popen )
import Yi.Editor
import Yi.CoreUI
import Yi.Kernel
import Yi.Event (eventToChar, Event)
import Yi.Keymap
import Yi.Buffer.Region
import qualified Yi.Interact as I
import Yi.Monad
import Yi.Accessor
import qualified Yi.WindowSet as WS
import qualified Yi.Editor as Editor
import qualified Yi.Style as Style
import qualified Yi.UI.Common as UI
import Yi.UI.Common as UI (UI)
import Yi.Keymap.Emacs.Keys
import Data.Maybe
import qualified Data.Map as M
import Data.List
  ( notElem
  , delete
  )
import Data.IORef
import Data.Foldable

import System.FilePath

import Control.Monad (when, forever)
import Control.Monad.Reader (runReaderT, ask)
import Control.Monad.Trans
import Control.Monad.State (gets, modify)
import Control.Monad.Error ()
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Chan
import Yi.History

-- | Open a minibuffer window with the given prompt and keymap
spawnMinibufferE :: String -> KeymapEndo -> YiM () -> YiM ()
spawnMinibufferE prompt kmMod initialAction =
    do b <- withEditor $ stringToNewBuffer prompt []
       setBufferKeymap b kmMod
       withEditor $ modifyWindows (WS.add $ Window True b 0 0 0)
       initialAction

-- | @withMinibuffer prompt completer act@: open a minibuffer with @prompt@. Once a string @s@ is obtained, run @act s@. @completer@ can be used to complete functions.
withMinibuffer :: String -> (String -> YiM String) -> (String -> YiM ()) -> YiM ()
withMinibuffer prompt completer act = do
  initialBuffer <- withEditor getBuffer
  let innerAction :: YiM ()
      -- ^ Read contents of current buffer (which should be the minibuffer), and
      -- apply it to the desired action
      closeMinibuffer = closeBufferAndWindowE
      innerAction = do withEditor $ historyFinish
                       lineString <- withBuffer elemsB
                       withEditor $ closeMinibuffer
                       switchToBufferE initialBuffer
                       -- The above ensures that the action is performed on the buffer that originated the minibuffer.
                       act lineString
      rebindings = [("RET", write innerAction),
                    ("C-m", write innerAction),
                    ("M-p", write historyUp),
                    ("M-n", write historyDown),
                    ("<up>", write historyUp),
                    ("<down>", write historyDown),
                    ("C-i", write (completionFunction completer)),
                    ("TAB", write (completionFunction completer)),
                    ("C-g", write closeMinibuffer)]
  withEditor $ historyStart
  spawnMinibufferE (prompt ++ " ") (rebind rebindings) (return ())

completionFunction :: (String -> YiM String) -> YiM ()
completionFunction f = do
  p <- withBuffer pointB
  text <- withBuffer $ readRegionB $ mkRegion 0 p
  compl <- f text
  -- it's important to do this before removing the text,
  -- so if the completion function raises an exception, we don't delete the buffer contents.
  withBuffer $ do moveTo 0
                  deleteN p
                  insertN compl
