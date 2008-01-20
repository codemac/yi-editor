--
-- Copyright (c) 2008 JP Bernardy
--
--

module Yi.Window where

import Yi.Buffer.Implementation (Point)
type BufferRef = Int

------------------------------------------------------------------------
-- | A window onto a buffer.

data Window = Window {
                      isMini :: !Bool   -- ^ regular or mini window?
                     ,bufkey :: !BufferRef -- ^ the buffer this window opens to
                     ,tospnt :: !Int    -- ^ the buffer point of the top of screen
                     ,bospnt :: !Int    -- ^ the buffer point of the bottom of screen
                     ,height :: !Int    -- ^ height of the window (in number of lines displayed)
                     }
-- | Get the identification of a window.
winkey :: Window -> (Bool, BufferRef)
winkey w = (isMini w, bufkey w)

instance Show Window where
    show w = "Window to " ++ show (bufkey w) ++ "{" ++ show (height w) ++ "}"

pointInWindow :: Point -> Window -> Bool
pointInWindow point win = tospnt win <= point && point <= bospnt win

-- | Return a "fake" window onto a buffer.
dummyWindow :: BufferRef -> Window
dummyWindow b = Window False b 0 0 0
