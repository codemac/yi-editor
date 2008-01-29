{-# LANGUAGE DeriveDataTypeable #-}

-- Copyright (c) 2005,8 Jean-Philippe Bernardy

module Yi.Keymap.Emacs.KillRing where

import Yi.Keymap.Emacs.UnivArgument
import Yi.Buffer.Region
import Yi.Keymap
import Yi.Buffer
import Yi.Buffer.HighLevel
import Yi.Accessor
import Yi.Editor
import Control.Monad ( when, replicateM_ )
import Yi.KillRing


-- * Killring actions


--- | C-w
killRegionE :: YiM ()
killRegionE = do r <- withBuffer getSelectRegionB
                 text <- withBuffer $ readRegionB r
                 killringPut text
                 withBuffer unsetMarkB
                 withBuffer $ deleteRegionB r

-- | C-k
killLineE :: YiM ()
killLineE = withUnivArg $ \a -> case a of
               Nothing -> killRestOfLineE
               Just n -> replicateM_ (2*n) killRestOfLineE

killringPut :: String -> YiM ()
killringPut s = withEditor $ modifyA killringA $ krPut s

-- | Kill the rest of line
killRestOfLineE :: YiM ()
killRestOfLineE =
    do eol <- withBuffer atEol
       l <- withBuffer readRestOfLnB
       killringPut l
       withBuffer deleteToEol
       when eol $
            do c <- withBuffer readB
               killringPut [c]
               withBuffer (deleteN 1)

-- | C-y
yankE :: EditorM ()
yankE = do (text:_) <- getsA killringA krContents
           withBuffer0 $ do pointB >>= setSelectionMarkPointB
                            insertN text
                            unsetMarkB

-- | M-w
killRingSaveE :: YiM ()
killRingSaveE = do text <- withBuffer (readRegionB =<< getSelectRegionB)
                   killringPut text
                   withBuffer unsetMarkB
-- | M-y

-- TODO: Handle argument, verify last command was a yank
yankPopE :: EditorM ()
yankPopE = do withBuffer0 (deleteRegionB =<< getSelectRegionB)
              modifyA killringA $ \kr ->
                  let ring = krContents kr
                  in kr {krContents = tail ring ++ [head ring]}
              yankE

-- | C-M-w
appendNextKillE :: YiM ()
appendNextKillE = withEditor $ modifyA killringA (\kr -> kr {krKilled=True})
