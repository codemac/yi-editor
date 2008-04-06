import Yi
import Yi.Keymap.Emacs (keymap)
import qualified Yi.Mode.Shim as Shim
import Yi.UI.Common (UIConfig(..))
import Yi.Modes
import Data.List (isSuffixOf)
import Yi.Prelude
import Prelude ()

bestHaskellMode :: Mode
bestHaskellMode = cleverHaskellMode 
 {
  modeKeymap = modeKeymap Shim.mode
 }

myModetable :: ReaderT String Maybe Mode
myModetable = ReaderT $ \fname -> case () of 
                        _ | ".hs" `isSuffixOf` fname -> Just bestHaskellMode
                        _ ->  Nothing


main :: IO ()
main = yi $ defaultConfig {
                           modeTable = myModetable <|> modeTable defaultConfig,
                           configUI = UIConfig { configFontSize = Just 10 },
                           defaultKm = keymap
                          }
