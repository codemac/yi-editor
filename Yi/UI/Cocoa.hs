{-# LANGUAGE TemplateHaskell, ForeignFunctionInterface, ExistentialQuantification, TypeSynonymInstances, FlexibleInstances, MultiParamTypeClasses, DeriveDataTypeable #-}
--
-- Copyright (c) 2007, 2008 Jean-Philippe Bernardy
-- Copyright (c) 2008 Gustav Munkby
--

-- | This module defines a user interface implemented using Cocoa.

module Yi.UI.Cocoa (start) where

import Prelude hiding (init, length, error, sequence_, elem, mapM_, mapM, concat, concatMap)

import Yi.UI.Cocoa.Application
import Yi.UI.Cocoa.TextStorage
import Yi.UI.Cocoa.TextView
import Yi.UI.Cocoa.Utils

import Yi.Prelude hiding (init)
import Yi.Buffer
import Yi.Editor
import Yi.Keymap
import Yi.Monad
import Yi.Config
import qualified Yi.UI.Common as Common
import qualified Yi.WindowSet as WS
import qualified Yi.Style as Style
import Yi.Window
import Paths_yi (getDataFileName)

import Control.Monad.Reader (when)

import qualified Data.List as L
import Data.IORef
import Data.Maybe
import Data.Unique
import qualified Data.Map as M

import Foundation hiding (name, new, parent, error, self, null)

import AppKit hiding (windows, start, rect, width, content, prompt, dictionary, icon, concat, remove, insert, update)
import qualified AppKit.NSWindow
import qualified AppKit.NSView

import Foreign.C
import Foreign hiding (new)

foreign import ccall "Processes.h TransformProcessType" transformProcessType :: Ptr (CInt) -> CInt -> IO (CInt)
foreign import ccall "Processes.h SetFrontProcess" setFrontProcess :: Ptr (CInt) -> IO (CInt)
foreign import ccall "Processes.h GetCurrentProcess" getCurrentProcess :: Ptr (CInt) -> IO (CInt)

------------------------------------------------------------------------

data UI = UI {uiWindow :: NSWindow ()
             ,uiBox :: NSSplitView ()
             ,uiCmdLine :: NSTextField ()
             ,uiBuffers :: IORef (M.Map BufferRef TextStorage)
             ,windowCache :: IORef [WinInfo]
             ,uiActionCh :: Action -> IO ()
             ,uiConfig :: UIConfig
             }

data WinInfo = WinInfo
  { wikey    :: !Unique        -- ^ Uniquely identify each window
  , window   :: Window         -- ^ The editor window that we reflect
  , textview :: YiTextView ()
  , modeline :: NSTextField ()
  , widget   :: NSView ()      -- ^ Top-level widget for this window.
  }

mkUI :: UI -> Common.UI
mkUI ui = Common.UI
  {
   Common.main                  = main,
   Common.end                   = end,
   Common.suspend               = uiWindow ui # performMiniaturize nil,
   Common.refresh               = refresh ui,
   Common.prepareAction         = return (return ()),
   Common.reloadProject         = \_ -> return ()
  }

rect :: Float -> Float -> Float -> Float -> NSRect
rect x y w h = NSRect (NSPoint x y) (NSSize w h)

allSizable, normalWindowMask :: CUInt
allSizable = nsViewWidthSizable .|. nsViewHeightSizable
normalWindowMask =
  nsTitledWindowMask .|. nsResizableWindowMask .|. nsClosableWindowMask .|. nsMiniaturizableWindowMask

initWithContentRect :: NSRect -> NewlyAllocated (NSWindow ()) -> IO (NSWindow ())
initWithContentRect r =
  initWithContentRectStyleMaskBackingDefer r normalWindowMask nsBackingStoreBuffered True

toNSView :: forall t. ID () -> NSView t
toNSView = castObject

toYiApplication :: forall t1 t2. NSApplication t1 -> YiApplication t2
toYiApplication = castObject
toYiController :: forall t1 t2. NSObject t1 -> YiController t2
toYiController = castObject

newTextLine :: IO (NSTextField ())
newTextLine = do
  tl <- new _NSTextField
  tl # setAlignment nsLeftTextAlignment
  tl # setAutoresizingMask (nsViewWidthSizable .|. nsViewMaxYMargin)
  tl # setMonospaceFont
  tl # setSelectable True
  tl # setEditable False
  tl # setBezeled False
  tl # sizeToFit
  cl <- castObject <$> tl # cell :: IO (NSCell ())
  cl # setWraps False
  cl # setLineBreakMode nsLineBreakByTruncatingMiddle
  return tl

addSubviewWithTextLine :: forall t1 t2. NSView t1 -> NSView t2 -> IO (NSTextField (), NSView ())
addSubviewWithTextLine view parent = do
  container <- new _NSView
  parent # bounds >>= flip setFrame container
  container # setAutoresizingMask allSizable
  view # setAutoresizingMask allSizable
  container # addSubview view

  text <- newTextLine
  container # addSubview text
  parent # addSubview container
  -- Adjust frame sizes, as superb cocoa cannot do this itself...
  txtbox <- text # frame
  winbox <- container # bounds
  view # setFrame (rect 0 (nsHeight txtbox) (nsWidth winbox) (nsHeight winbox - nsHeight txtbox))
  text # setFrame (rect 0 0 (nsWidth winbox) (nsHeight txtbox))

  return (text, container)

-- | Initialise the ui
start :: UIBoot
start cfg ch outCh _ed = do

  -- Ensure that our command line application is also treated as a gui application
  fptr <- mallocForeignPtrBytes 32 -- way to many bytes, but hey...
  withForeignPtr fptr $ getCurrentProcess
  withForeignPtr fptr $ (flip transformProcessType) 1
  withForeignPtr fptr $ setFrontProcess

  -- Publish Objective-C classes...
  initializeClass_Application
  initializeClass_YiTextView
  initializeClass_TextStorage
  initializeClass_YiScrollView

  app <- _YiApplication # sharedApplication >>= return . toYiApplication
  app # setIVar _eventChannel (Just ch)

  -- Multithreading in Cocoa is initialized by spawning a new thread
  -- This spawns a thread that immediately exits, but that's okay
  _NSThread # detachNewThreadSelectorToTargetWithObject
     (getSelectorForName "sharedApplication") _YiApplication nil

  -- Set the application icon accordingly
  icon <- getDataFileName "art/yi+lambda-fat.pdf"
  _NSImage # alloc >>=
    initWithContentsOfFile (toNSString icon) >>=
    flip setApplicationIconImage app

  -- Initialize the app delegate, which allows quit-on-window-close
  controller <- autonew _YiController >>= return . toYiController
  app # setDelegate controller

  -- init menus
  mm <- _NSMenu # alloc >>= init
  mm' <- _NSMenu # alloc >>= init
  mm'' <- _NSMenu # alloc >>= init
  app # setMainMenu mm
  app # setAppleMenu mm'
  app # setWindowsMenu mm''


  -- Create main cocoa window...
  win <- _NSWindow # alloc >>= initWithContentRect (rect 0 0 480 340)
  win # setTitle (toNSString "Yi")
  content <- win # AppKit.NSWindow.contentView >>= return . toNSView
  content # setAutoresizingMask allSizable

  -- Create yi window container
  winContainer <- new _NSSplitView
  (cmd,_) <- content # addSubviewWithTextLine winContainer

  -- Activate application window
  win # center
  win # setFrameAutosaveName (toNSString "main")
  win # makeKeyAndOrderFront nil
  app # activateIgnoringOtherApps False

  -- Update the font configuration if desired...
  case configFontSize $ configUI cfg of
    Just fontSize ->
      userFixedPitchFontOfSize (fromIntegral fontSize) _NSFont >>=
          flip setUserFixedPitchFont _NSFont
    Nothing ->
      return ()

  bufs <- newIORef M.empty
  wc <- newIORef []

  let ui = UI win winContainer cmd bufs wc (outCh . singleton) (configUI cfg)

  cmd # setColors ui Style.window

  return (mkUI ui)

-- | Run the main loop
main :: IO ()
main = _YiApplication # sharedApplication >>= run

-- | Clean up and go home
end :: IO ()
end = _YiApplication # sharedApplication >>= terminate_ nil

syncWindows :: Editor -> UI -> [(Window, Bool)] -> [WinInfo] -> IO [WinInfo]
syncWindows e ui = sync
  where 
    sync ws [] = mapM insert ws
    sync [] cs = mapM_ remove cs >> return []
    sync (w:ws) (c:cs)
      | match w c          = (:) <$> update w c <*> sync ws cs
      | L.any (match w) cs = remove c >> sync (w:ws) cs
      | otherwise          = (:) <$> insert w <*> sync ws (c:cs)

    match w c = winkey (fst w) == winkey (window c)

    winbuf = flip findBufferWith e . bufkey

    remove = removeFromSuperview . widget
    insert (w,f) = update (w,f) =<< newWindow ui w (winbuf w)
    update (w, False) i = return (i{window = w})
    update (w, True) i = do
      (textview i) # AppKit.NSView.window >>= makeFirstResponder (textview i)
      return (i{window = w})

setColors :: (Has_setBackgroundColor t, Has_setTextColor t) => UI -> Style.StyleName -> t -> IO ()
setColors ui styleName slf = do
  let s = styleName $ configStyle $ uiConfig ui
  getColor True  (Style.foreground s) >>= flip setTextColor slf
  getColor False (Style.background s) >>= flip setBackgroundColor slf

-- | Make A new window
newWindow :: UI -> Window -> FBuffer -> IO WinInfo
newWindow ui win b = do
  v <- alloc _YiTextView >>= initWithFrame (rect 0 0 100 100)
  v # setRichText False
  v # setSelectable True
  v # setAlignment nsLeftTextAlignment
  v # sizeToFit
  attrs <- convertStyle $ Style.selected $ configStyle $ uiConfig ui
  v # setSelectedTextAttributes attrs
  v # setColors ui Style.window
  v # textColor >>= flip setInsertionPointColor v

  (ml, view) <- if (isMini win)
   then do
    v # setHorizontallyResizable False
    v # setVerticallyResizable False
    prompt <- newTextLine
    prompt # setStringValue (toNSString (name b))
    prompt # sizeToFit
    prompt # setAutoresizingMask nsViewNotSizable
    prompt # setBordered False
    prompt # setColors ui Style.window

    prect <- prompt # frame
    vrect <- v # frame

    hb <- _NSView # alloc >>= initWithFrame (rect 0 0 (nsWidth prect + nsWidth vrect) (nsHeight prect))
    v # setFrame (rect (nsWidth prect) 0 (nsWidth vrect) (nsHeight prect))
    v # setAutoresizingMask nsViewWidthSizable
    hb # addSubview prompt
    hb # addSubview v
    hb # setAutoresizingMask nsViewWidthSizable

    brect <- (uiBox ui) # bounds
    hb # setFrame (rect 0 0 (nsWidth brect) (nsHeight prect))

    (uiBox ui) # addSubview hb
    dummy <- _NSTextField # alloc >>= init

    return (dummy, hb)
   else do
    v # setHorizontallyResizable True
    v # setVerticallyResizable True
    
    when (not $ configLineWrap $ uiConfig ui) $ do
      tc <- v # textContainer
      NSSize _ h <- tc # containerSize
      tc # setContainerSize (NSSize 1.0e7 h)
      tc # setWidthTracksTextView False

    scroll <- new _YiScrollView
    scroll # setDocumentView v
    scroll # setAutoresizingMask allSizable

    scroll # setHasVerticalScroller True
    scroll # setHasHorizontalScroller False
    scroll # setAutohidesScrollers (configAutoHideScrollBar $ uiConfig ui)
    scroll # setIVar _leftScroller (configLeftSideScrollBar $ uiConfig ui)
    addSubviewWithTextLine scroll (uiBox ui)

  ml # setColors ui Style.modeline
  storage <- getTextStorage ui b
  layoutManager v >>= replaceTextStorage storage

  k <- newUnique
  flip (setIVar _runBuffer) v $ \act -> do
    wCache <- readIORef (windowCache ui)
    uiActionCh ui $ makeAction $ do
      modifyWindows $ WS.focusIndex $ fromJust $ L.findIndex ((k ==) . wikey) wCache
      withGivenBufferAndWindow0 win (keyB b) act

  return $ WinInfo 
    { wikey    = k
    , window   = win
    , textview = v
    , modeline = ml
    , widget   = view
    }

refresh :: UI -> Editor -> IO ()
refresh ui e = logNSException "refresh" $ do
    (uiCmdLine ui) # setStringValue (toNSString $ statusLine e)

    cache <- readRef $ windowCache ui
    forM_ (buffers e) $ \buf -> do
      storage <- getTextStorage ui buf
      storage # setMonospaceFont -- FIXME: Why is this needed for mini buffers?
      storage # setTextStorageBuffer buf

    (uiWindow ui) # setAutodisplay False -- avoid redrawing while window syncing
    cache' <- syncWindows e ui (toList $ WS.withFocus $ windows e) cache
    writeRef (windowCache ui) cache'
    (uiBox ui) # adjustSubviews -- FIX: maybe it is not needed
    (uiWindow ui) # setAutodisplay True -- reenable automatic redrawing

    forM_ cache' $ \w ->
        do let buf = findBufferWith (bufkey (window w)) e
           let ((p0,p1,showSel,txt),_) = runBuffer (window w) buf $
                 (,,,) <$> pointB <*> getMarkPointB staticSelMark <*>
                           getA highlightSelectionA <*> getModeLine
           let (p,l) = if showSel then (min p0 p1, abs $ p1~-p0) else (p0,0)
           (textview w) # setSelectedRange (NSRange (fromIntegral p) (fromIntegral l))
           (textview w) # scrollRangeToVisible (NSRange (fromIntegral p0) 0)
           -- Signal to Cocoa that we need to update attributes in the visible range...
           storage <- castObject <$> (textview w) # textStorage
           visRange <- (textview w) # visibleRange
           storage # visibleRangeChanged visRange
           (modeline w) # setStringValue (toNSString txt)

getTextStorage :: UI -> FBuffer -> IO TextStorage
getTextStorage ui b = do
    let bufsRef = uiBuffers ui
    bufs <- readRef bufsRef
    storage <- case M.lookup (bkey b) bufs of
      Just storage -> return storage
      Nothing -> newTextStorage (configStyle $ uiConfig ui) b
    modifyRef bufsRef (M.insert (bkey b) storage)
    return storage
