{-# LANGUAGE Rank2Types #-}

module Yi.UI.Common where

import Yi.Editor
import Yi.Event
import {-# SOURCE #-} Yi.Keymap

data UIConfig = UIConfig {
   configFontSize :: Maybe Int,
   configLeftSideScrollBar :: Bool,
   configAutoHideScrollBar :: Bool,
   configLineWrap :: Bool
  }


data UI = UI
    {
     main                  :: IO (),           -- ^ Main loop
     end                   :: IO (),           -- ^ Clean up
     suspend               :: IO (),           -- ^ Suspend (or minimize) the program
     refresh               :: Editor -> IO (), -- ^ Refresh the UI with the given state
     prepareAction         :: IO (EditorM ())  -- ^ Ran before an action is executed
    }

type UIBoot = UIConfig -> (Event -> IO ()) -> (Action -> IO ()) ->  Editor -> IO UI
