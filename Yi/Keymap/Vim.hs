{-# LANGUAGE FlexibleContexts, DeriveDataTypeable #-}

--
-- Copyright (c) 2004-5 Don Stewart - http://www.cse.unsw.edu.au/~dons
--
--


-- | Vim keymap for Yi. Emulates vim :set nocompatible
module Yi.Keymap.Vim ( keymap, VimMode, viWrite ) where

import Yi.Yi
import Yi.Style as Style
import Prelude       hiding ( any, error )

import Data.Char
import Data.Maybe           ( fromMaybe )
import Data.Dynamic
import qualified Data.Map as M

import Control.Exception    ( ioErrors, try, evaluate )
import Control.Monad.State

import Yi.Editor
import Yi.Accessor
import Yi.History
import Yi.Buffer
import Yi.Debug

import Yi.Indent

import Yi.Keymap.Emacs.Utils (completeFileName,completeBufferName)
import Yi.MiniBuffer
import Yi.TextCompletion
import Yi.Syntax.Table (highlighters)

--
-- What's missing?
--   fancier :s//
--   '.'
--   movement parameterised \> \<
--

{-
  For now we just make the selected style the same as the
  modeline_focused style... Just because i'm not good with
  styles yet - Jim
-}
defaultVimUiStyle :: Style.UIStyle
defaultVimUiStyle = Style.uiStyle { selected = Style.modeline_focused Style.uiStyle}

-- ---------------------------------------------------------------------

type VimMode = VimProc ()

type VimProc a = (Interact Char) a


-- | Top level
keymap :: Keymap
keymap = do write $ do setWindowFillE '~'
                       withBuffer0 unsetMarkB
                       setWindowStyleE defaultVimUiStyle
            runVim cmd_mode

runVim :: VimMode -> Keymap
runVim = comap eventToChar

------------------------------------------------------------------------

-- The Vim VimProc is divided into several parts, roughly corresponding
-- to the different modes of vi. Each mode is in turn broken up into
-- separate VimProcs for each phase of key input in that mode.

-- | Command mode consists of simple commands that take a count arg,
-- the replace cmd, which consumes one char of input, and commands
-- that switch modes.
cmd_mode :: VimMode
cmd_mode = choice [cmd_eval,eval cmd_move,cmd2other,cmd_op]

-- | Take a VimMode that returns and action; "run" it and write the returned action.
eval :: YiAction a () => VimProc (b, a) -> VimMode
eval p = do (_, a) <- p; write a

-- | Leave a mode. This always has priority over catch-all actions inside the mode.
leave :: VimMode
leave = event '\ESC' >> adjustPriority (-1) (write msgClr)

-- | Insert mode is either insertion actions, or the meta (\ESC) action
ins_mode :: VimMode
ins_mode = write (msgEditor "-- INSERT --") >> many (ins_char <|> kwd_mode) >> leave

-- | Replace mode is like insert, except it performs writes, not inserts
rep_mode :: VimMode
rep_mode = write (msgEditor "-- REPLACE --") >> many rep_char >> leave

-- | Visual mode, similar to command mode
vis_mode :: RegionStyle -> VimMode
vis_mode regionStyle = do
  write (withBuffer (pointB >>= setSelectionMarkPointB))
  core_vis_mode regionStyle
  write (msgClr >> withBuffer unsetMarkB >> withBuffer (setDynamicB $ SelectionStyle Character))

core_vis_mode :: RegionStyle -> VimMode
core_vis_mode regionStyle = do
  write $ withEditor $ do setA regionStyleA regionStyle
                          withBuffer0 $ setDynamicB $ SelectionStyle $
                            case regionStyle of { LineWise -> fullLine; CharWise -> Character }
                          printMsg $ msg regionStyle
  many (eval cmd_move)
  (vis_single regionStyle <|| vis_multi)
  where msg CharWise = "-- VISUAL --"
        msg LineWise = "-- VISUAL LINE --"

-- | Change visual mode
change_vis_mode :: RegionStyle -> RegionStyle -> VimMode
change_vis_mode src dst | src == dst = return ()
change_vis_mode _   dst              = core_vis_mode dst

-- | A VimProc to accumulate digits.
-- typically what is needed for integer repetition arguments to commands
count :: VimProc (Maybe Int)
count = option Nothing $ do
    c <- satisfy isDigitNon0
    cs <- many (satisfy isDigit)
    return $ Just $ read (c:cs)
  where isDigitNon0 '0' = False
        isDigitNon0 x   = isDigit x

data RegionStyle = LineWise
                 | CharWise
  deriving (Eq, Typeable, Show)

instance Initializable RegionStyle where
  initial = CharWise

regionStyleToUnit :: RegionStyle -> TextUnit
regionStyleToUnit LineWise = fullLine
regionStyleToUnit CharWise = Character

fullLine :: TextUnit
fullLine = GenUnit {genEnclosingUnit=Document, genUnitBoundary=bound}
  where bound d = withOffset d $ atBoundaryB Line d
        withOffset Backward f = f
        withOffset Forward  f = savingPointB (leftB >> f)

regionStyleA :: Accessor Editor RegionStyle
regionStyleA = dynamicValueA .> dynamicA

-- ---------------------------------------------------------------------
-- | VimProc for movement commands
--
-- The may be invoked directly, or sometimes as arguments to other
-- /operator/ commands (like d).
--

cmd_move :: VimProc (RegionStyle, BufferM ())
cmd_move = do
  cnt <- count
  let x = maybe 1 id cnt
  choice ([event c >> return (CharWise, a x) | (c,a) <- moveCmdFM, (c /= '0' || Nothing == cnt) ] ++
          [event c >> return (LineWise, a x) | (c,a) <- moveUpDownCmdFM] ++
          [do event c; c' <- anyEvent; return (CharWise, a x c') | (c,a) <- move2CmdFM] ++
          [do event 'G'; return (LineWise, case cnt of
                                       Nothing -> botB >> moveToSol
                                       Just n  -> gotoLn n >> return ())
          ,do events "gg"; return (LineWise, gotoLn 0 >> return ())
          ,do events "ge"; return (CharWise, replicateM_ x $ genMoveB ViWord (Forward, InsideBound) Backward)])

-- | movement commands
moveCmdFM :: [(Char, Int -> BufferM ())]
moveCmdFM =
-- left/right
    [('h',          left)
    ,('\^H',        left)
    ,(keyBackspace, left)
    ,('\BS',        left)
    ,('\127',       left)
    ,(keyLeft,      left)
    ,(keyRight,     right)
    ,('l',          right)
    ,(' ',          right)
    ,(keyHome,      sol)
    ,('0',          sol)
    ,('^',          const firstNonSpaceB)
    ,('$',          eol)
    ,(keyEnd,       eol)
    ,('|',          \i -> moveToSol >> moveXorEol (i-1))

-- words
    ,('w',          \i -> replicateM_ i $ genMoveB ViWord (Backward,InsideBound) Forward)
    ,('b',          \i -> replicateM_ i $ genMoveB ViWord (Backward,InsideBound) Backward)
    ,('e',          \i -> replicateM_ i $ genMoveB ViWord (Forward, InsideBound) Forward)

-- text
    ,('{',          prevNParagraphs)
    ,('}',          nextNParagraphs)

-- misc
    ,('H',          \i -> downFromTosB (i - 1))
    ,('M',          const middleB)
    ,('L',          \i -> upFromBosB (i - 1))
    ]
    where
        left  = moveXorSol
        right = moveXorEol
        sol   _ = moveToSol
        eol   _ = moveToEol

-- | up/down movement commands. these one are separated from moveCmdFM
-- because they behave differently when yanking/cuting (line mode).
moveUpDownCmdFM :: [(Char, Int -> BufferM ())]
moveUpDownCmdFM =
    [('k',          up)
    ,(keyUp,        up)
    ,('\^P',        up)
    ,('j',          down)
    ,(keyDown,      down)
    ,('\^J',        down)
    ,('\^N',        down)
    ,('\r',         down)
    ]
    where
        up   i = lineMoveRel (-i) >> return ()
        down i = lineMoveRel i    >> return ()

--  | more movement commands. these ones are paramaterised by a character
-- to find in the buffer.
move2CmdFM :: [(Char, Int -> Char -> BufferM ())]
move2CmdFM =
    [('f',  \i c -> replicateM_ i $ nextCInc c)
    ,('F',  \i c -> replicateM_ i $ prevCInc c)
    ,('t',  \i c -> replicateM_ i $ nextCExc c)
    ,('T',  \i c -> replicateM_ i $ prevCExc c)
    ]

-- | Other command mode functions
cmd_eval :: VimMode
cmd_eval = do
   cnt <- count
   let i = maybe 1 id cnt
   choice
    ([event c >> write (a i) | (c,a) <- singleCmdFM ] ++
    [events evs >> write (action i) | (evs, action) <- multiCmdFM ]) <|>
    (do event 'r'; c <- anyButEscOrDel; write (writeB c)) <|>
    (events ">>" >> write (shiftIndentOfLine i)) <|>
    (events "<<" >> write (shiftIndentOfLine (-i))) <|>
    (events "ZZ" >> write (viWrite >> quitEditor))

-- TODO: escape the current word
--       at word bounds: search for \<word\>
searchCurrentWord :: YiM ()
searchCurrentWord = do
  w <- withBuffer $ readRegionB =<< regionOfB ViWord
  doSearch (Just w) [] Forward

anyButEscOrDel :: VimProc Char
anyButEscOrDel = satisfy (not . (`elem` ('\ESC':delete')))

continueSearching :: Direction -> YiM ()
continueSearching direction = do
  withEditor $ getRegexE >>= printMsg . ("/" ++) . fst . fromMaybe ([],undefined)
  doSearch Nothing [] direction

-- | cmd mode commands
singleCmdFM :: [(Char, Int -> YiM ())]
singleCmdFM =
    [('\^B',    withBuffer . upScreensB)             -- vim does (firstNonSpaceB;moveXorSol)
    ,('\^F',    withBuffer . downScreensB)
    ,('\^G',    const viFileInfo)        -- hmm. not working. duh. we clear
    ,('\^L',    const refreshEditor)
    ,('\^R',    withBuffer . flip replicateM_ redoB)
    ,('\^Z',    const suspendEditor)
    ,('D',      const (withEditor $ withBuffer0 readRestOfLnB >>= setRegE >> withBuffer0 deleteToEol))
    ,('J',      const (withBuffer (moveToEol >> deleteN 1)))    -- the "\n"
    ,('U',      withBuffer . flip replicateM_ undoB)    -- NB not correct
    ,('n',      const $ continueSearching Forward)
    ,('u',      withBuffer . flip replicateM_ undoB)

    ,('X',      \i -> withBuffer $ do p <- pointB
                                      moveXorSol i
                                      q <- pointB
                                      when (p-q > 0) $ deleteN (p-q) )

    ,('x',      \i -> withBuffer $ do p <- pointB -- not handling eol properly
                                      moveXorEol i
                                      q <- pointB
                                      moveTo p
                                      when (q-p > 0) $ deleteN (q-p))

    ,('p',      withEditor . flip replicateM_ pasteAfter)

    ,('P',      withEditor . flip replicateM_ pasteBefore)

    ,(keyPPage, withBuffer . upScreensB)
    ,(keyNPage, withBuffer . downScreensB)
    ,('*',      const $ searchCurrentWord)
    ,('~',      \i -> withBuffer $ do
                         p <- pointB
                         moveXorEol i
                         q <- pointB
                         moveTo p
                         mapRegionB (mkRegion p q) $ \c ->
                             if isUpper c then toLower c else toUpper c
                         moveTo q)
    ]

multiCmdFM :: [(String, Int -> YiM ())]
multiCmdFM =
    [("\^Wc", const $ withEditor tryCloseE)
    ,("\^Wo", const $ withEditor closeOtherE)
    ,("\^Ws", const $ withEditor splitE)
    ,("\^Ww", const $ withEditor nextWinE)
    ,("\^WW", const $ withEditor prevWinE)
    ,("\^Wp", const $ withEditor prevWinE)

    -- since we don't have vertical splitting,
    -- these moving can be done using next/prev.
    ,(['\^W',keyDown], const $ withEditor nextWinE)
    ,(['\^W',keyUp], const $ withEditor prevWinE)
    ,(['\^W',keyRight], const $ withEditor nextWinE)
    ,(['\^W',keyLeft], const $ withEditor prevWinE)
    ]

-- | So-called 'operators', which take movement actions as arguments.
--
-- How do we achive this? We parse a known operator char then parse
-- one of the known movement commands.  We then apply the returned
-- action and then the operator. For example, we 'd' command stores
-- the current point, does a movement, then deletes from the old to
-- the new point.
cmd_op :: VimMode
cmd_op = do
  cnt <- count
  let i = maybe 1 id cnt
  choice $ [events "dd" >> write (cut  pointB (lineMoveRel (i-1) >> return ()) LineWise),
            events "yy" >> write (yank pointB (lineMoveRel (i-1) >> return ()) LineWise)] ++
           [do event c
               (regionStyle, m) <- cmd_move
               write $ a (replicateM_ i m) regionStyle
           | (c,a) <- opCmdFM]
    where
        -- | operator (i.e. movement-parameterised) actions
        opCmdFM :: [(Char, BufferM () -> RegionStyle -> EditorM ())]
        opCmdFM =
            [('d', cut  pointB),
             ('y', yank pointB)]

regionFromTo :: BufferM Point -> BufferM () -> RegionStyle -> BufferM Region
regionFromTo mstart move regionStyle = do
  start <- mstart
  move
  stop <- pointB
  let region = mkRegion start stop
  unitWiseRegion (regionStyleToUnit regionStyle) region

yank :: BufferM Point -> BufferM () -> RegionStyle -> EditorM ()
yank mstart move regionStyle = do
  txt <- withBuffer0 $ do
    p <- pointB
    region <- regionFromTo mstart move regionStyle
    moveTo p
    readRegionB region
  setRegE $ if (regionStyle /= CharWise) then '\n':txt else txt
  let rowsYanked = length (filter (== '\n') txt)
  when (rowsYanked > 2) $ printMsg $ (show rowsYanked) ++ " lines yanked"

cut :: BufferM Point -> BufferM () -> RegionStyle -> EditorM ()
cut mstart move regionStyle = do
  txt <- withBuffer0 $ do
    region <- regionFromTo mstart move regionStyle
    txt <- readRegionB region
    deleteRegionB region
    return txt
  setRegE $ if (regionStyle /= CharWise) then '\n':txt else txt
  let rowsCut = length (filter (== '\n') txt)
  when (rowsCut > 2) $ printMsg ( (show rowsCut) ++ " fewer lines")

cutSelection :: EditorM ()
cutSelection = cut getSelectionMarkPointB (return ()) =<< getA regionStyleA

yankSelection :: EditorM ()
yankSelection = yank getSelectionMarkPointB (return ()) =<< getA regionStyleA

pasteOverSelection :: EditorM ()
pasteOverSelection = do
  txt <- getRegE
  regionStyle <- getA regionStyleA
  withBuffer0 $ do
    region <- regionFromTo getSelectionMarkPointB (return ()) regionStyle
    moveTo $ regionStart region
    deleteRegionB region
    insertN txt

pasteAfter :: EditorM ()
pasteAfter = do
  txt' <- getRegE
  withBuffer0 $
    case txt' of
      '\n':txt -> moveToEol >> rightB >> insertN txt >> leftN (length txt)
      _      -> moveXorEol 1 >> insertN txt' >> leftB

pasteBefore :: EditorM ()
pasteBefore = do
  txt' <- getRegE
  withBuffer0 $ do
    case txt' of
      '\n':txt -> moveToSol >> insertN txt >> leftN (length txt)
      _      -> insertN txt' >> leftB

-- | Switching to another mode from visual mode.
--
-- All visual commands are meta actions, as they transfer control to another
-- VimProc. In this way vis_single is analogous to cmd2other
--
vis_single :: RegionStyle -> VimMode
vis_single regionStyle =
        let beginIns a = do write (a >> withBuffer0 unsetMarkB) >> ins_mode
        in choice [
            event '\ESC' >> return (),
            event 'V'    >> change_vis_mode regionStyle LineWise,
            event 'v'    >> change_vis_mode regionStyle CharWise,
            event ':'    >> ex_mode ":'<,'>",
            event 'y'    >> write yankSelection,
            event 'x'    >> write cutSelection,
            event 'd'    >> write cutSelection,
            event 'p'    >> write pasteOverSelection,
            event 'c'    >> beginIns cutSelection]


-- | These also switch mode, as all visual commands do, but these are
-- analogous to the commands in cmd_eval.  They are different in that
-- they are multiple characters
vis_multi :: VimMode
vis_multi = do
   cnt <- count
   let i = maybe 1 id cnt
   choice ([events "ZZ" >> write (viWrite >> quitEditor),
            events ">>" >> write (shiftIndentOfSelection i),
            events "<<" >> write (shiftIndentOfSelection (-i)),
            do event 'r'; x <- anyEvent; write $ do
                                   mrk <- getSelectionMarkPointB
                                   pt <- pointB
                                   text <- readRegionB (mkVimRegion mrk pt)
                                   moveTo mrk
                                   deleteRegionB (mkVimRegion mrk pt)
                                   let convert '\n' = '\n'
                                       convert  _   = x
                                   insertN $ map convert $ text] ++
           [event c >> write (a i) | (c,a) <- singleCmdFM ])


-- | Switch to another vim mode from command mode.
--
-- These commands are meta actions, as they transfer control to another
-- VimProc. Some of these commands also perform an action before switching.
--
cmd2other :: VimMode
cmd2other = let beginIns a = write a >> ins_mode
                beginIns :: EditorM () -> VimMode
        in choice [
            do event ':'     ; ex_mode ":",
            do event 'v'     ; vis_mode CharWise,
            do event 'V'     ; vis_mode LineWise,
            do event 'R'     ; rep_mode,
            do event 'i'     ; ins_mode,
            do event 'I'     ; beginIns (withBuffer0 moveToSol),
            do event 'a'     ; beginIns $ withBuffer0 $ moveXorEol 1,
            do event 'A'     ; beginIns (withBuffer0 moveToEol),
            do event 'o'     ; beginIns $ withBuffer0 $ moveToEol >> insertB '\n',
            do event 'O'     ; beginIns $ withBuffer0 $ moveToSol >> insertB '\n' >> lineUp,
            do event 'c'     ; (regionStyle, m) <- cmd_move ; beginIns $ cut pointB m regionStyle,
            do events "cc"   ; beginIns $ cut (moveToSol >> pointB) moveToEol CharWise,
            do event 'C'     ; beginIns $ cut pointB moveToEol CharWise, -- alias of "c$"
            do event 'S'     ; beginIns $ cut (moveToSol >> pointB) moveToEol CharWise, -- alias of "cc"
            do event 's'     ; beginIns $ cut pointB (moveXorEol 1) CharWise, -- alias of "cl"
            do event '/'     ; ex_mode "/",
            do event '?'     ; write $ not_implemented '?',
            leave,
            do event keyIC   ; ins_mode]


ins_mov_char :: VimMode
ins_mov_char = choice [event keyPPage >> write upScreenB,
                       event keyNPage >> write downScreenB,
                       event keyUp    >> write lineUp,
                       event keyDown  >> write lineDown,
                       event keyLeft  >> write (moveXorSol 1),
                       event keyRight >> write (moveXorEol 1),
                       event keyEnd   >> write moveToEol,
                       event keyHome  >> write moveToSol]


-- ---------------------------------------------------------------------
-- | vim insert mode
--
-- Some ideas for a better insert mode are contained in:
--
--      Poller and Garter , "A comparative study of moded and modeless
--      text editing by experienced editor users", 1983
--
-- which suggest that movement commands be added to insert mode, along
-- with delete.
--
ins_char :: VimMode
ins_char = choice [satisfy isDel  >> write (deleteB Character Backward),
                   event keyDC    >> write (deleteB Character Forward),
                   event '\t'     >> write insertTabB]
           <|> ins_mov_char
           <|| do c <- anyEvent; write (insertB c)

-- --------------------
-- | Keyword
kwd_mode :: VimMode
kwd_mode = some (event '\^N' >> adjustPriority (-1) (write wordCompleteB)) >> (write resetCompleteB)
           -- 'adjustPriority' is there to lift the ambiguity between "continuing" completion
           -- and resetting it (restarting at the 1st completion).

-- ---------------------------------------------------------------------
-- | vim replace mode
--
-- To quote vim:
--  In Replace mode, one character in the line is deleted for every character
--  you type.  If there is no character to delete (at the end of the line), the
--  typed character is appended (as in Insert mode).  Thus the number of
--  characters in a line stays the same until you get to the end of the line.
--  If a <NL> is typed, a line break is inserted and no character is deleted.
rep_char :: VimMode
rep_char = choice [satisfy isDel  >> write leftB, -- should undo unless pointer has been moved
                   event '\t'     >> write (insertN "    "),
                   event '\r'     >> write (insertB '\n')]
           <|> ins_mov_char
           <|| do c <- anyEvent; write (do e <- atEol; if e then insertB c else writeB c)

-- ---------------------------------------------------------------------
-- Ex mode. We also process regex searching mode here.

spawn_ex_buffer :: String -> YiM ()
spawn_ex_buffer prompt = do
  -- The above ensures that the action is performed on the buffer that originated the minibuffer.
  let ex_buffer_finish = do
        withEditor $ historyFinish
        lineString <- withBuffer elemsB
        withEditor closeBufferAndWindowE
        ex_eval (head prompt : lineString)
      ex_process :: VimMode
      ex_process =
          choice [enter         >> write ex_buffer_finish,
                  event '\t'    >> write completeMinibuffer,
                  event '\ESC'  >> write closeBufferAndWindowE,
                  delete        >> write bdeleteB,
                  event keyUp   >> write historyUp,
                  event keyDown >> write historyDown,
                  event keyLeft  >> write (moveXorSol 1),
                  event keyRight >> write (moveXorEol 1)]
             <|| (do c <- anyEvent; write $ insertB c)
      completeMinibuffer = withBuffer elemsB >>= ex_complete >>= withBuffer . insertN
      b_complete f = completeBufferName f >>= return . drop (length f)
      ex_complete ('e':' ':f) = completeFileName Nothing f >>= return . drop (length f)
      ex_complete ('b':' ':f)                             = b_complete f
      ex_complete ('b':'u':'f':'f':'e':'r':' ':f)         = b_complete f
      ex_complete ('b':'d':' ':f)                         = b_complete f
      ex_complete ('b':'d':'!':' ':f)                     = b_complete f
      ex_complete ('b':'d':'e':'l':'e':'t':'e':' ':f)     = b_complete f
      ex_complete ('b':'d':'e':'l':'e':'t':'e':'!':' ':f) = b_complete f
      ex_complete _ = return ""

  withEditor $ historyStart
  spawnMinibufferE prompt (const $ runVim $ ex_process) (return ())


ex_mode :: String -> VimMode
ex_mode = write . spawn_ex_buffer

-- | eval an ex command to an YiM (), also appends to the ex history
ex_eval :: String -> YiM ()
ex_eval cmd = do
  case cmd of
        -- regex searching
          ('/':pat) -> doSearch (Just pat) [] Forward

        -- TODO: We give up on re-mapping till there exists a generic Yi mechanism to do so.

        -- add mapping to command mode
          (_:'m':'a':'p':' ':_cs) -> error "Not yet implemented."

        -- add mapping to insert mode
          (_:'m':'a':'p':'!':' ':_cs) -> error "Not yet implemented."

        -- unmap a binding from command mode
          (_:'u':'n':'m':'a':'p':' ':_cs) -> error "Not yet implemented."

        -- unmap a binding from insert mode
          (_:'u':'n':'m':'a':'p':'!':' ':_cs) -> error "Not yet implemented."


        -- just a normal ex command
          (_:src) -> fn src

        -- can't happen, but deal with it
          [] -> return ()

    where
      whenUnchanged mu f = do u <- mu
                              if u then f
                                   else errorEditor "No write since last change (add ! to override)"
      quitB = whenUnchanged (withBuffer isUnchangedB) closeWindow

      quitNoW = do bufs <- withEditor $ do closeBufferE ""
                                           bufs <- gets bufferStack
                                           mapM (\x -> withGivenBuffer0 x isUnchangedB) bufs
                   whenUnchanged (return $ all id bufs) quitEditor

      quitall  = withAllBuffers quitB
      wquitall = withAllBuffers viWrite >> quitEditor
      bdelete  = whenUnchanged (withBuffer isUnchangedB) . withEditor . closeBufferE
      bdeleteNoW = withEditor . closeBufferE

      fn ""           = msgClr

      fn s@(c:_) | isDigit c = do
        e <- lift $ try $ evaluate $ read s
        case e of Left _ -> errorEditor $ "The " ++show s++ " command is unknown."
                  Right lineNum -> withBuffer (gotoLn lineNum) >> return ()

      fn "w"          = viWrite
      fn ('w':' ':f)  = viWriteTo f
      fn "qa"         = quitall
      fn "qal"        = quitall
      fn "qall"       = quitall
      fn "quita"      = quitall
      fn "quital"     = quitall
      fn "quitall"    = quitall
      fn "q"          = quitB
      fn "qu"         = quitB
      fn "qui"        = quitB
      fn "quit"       = quitB
      fn "q!"         = quitNoW
      fn "qu!"        = quitNoW
      fn "qui!"       = quitNoW
      fn "quit!"      = quitNoW
      fn "qa!"        = quitEditor
      fn "quita!"     = quitEditor
      fn "quital!"    = quitEditor
      fn "quitall!"   = quitEditor
      fn "wq"         = viWrite >> closeWindow
      fn "wqa"        = wquitall
      fn "wqal"       = wquitall
      fn "wqall"      = wquitall
      fn "x"          = do unchanged <- withBuffer isUnchangedB
                           unless unchanged viWrite
                           closeWindow
      fn "n"          = withEditor nextBufW
      fn "next"       = withEditor nextBufW
      fn "$"          = withBuffer botB
      fn "p"          = withEditor prevBufW
      fn "prev"       = withEditor prevBufW
      fn ('s':'p':_)  = withEditor splitE
      fn "e"          = revertE
      fn ('e':' ':f)  = fnewE f
      fn ('s':'e':'t':' ':'f':'t':'=':ft)  = withBuffer $ setSyntaxB $ highlighters M.! ft
      fn ('n':'e':'w':' ':f) = withEditor splitE >> fnewE f
      fn ('s':'/':cs) = viSub cs

      fn ('b':' ':"m") = withEditor $ switchToBufferWithNameE "*messages*"
      fn ('b':' ':f)   = withEditor $ switchToBufferWithNameE f
      fn "bd"                                    = bdelete ""
      fn "bdelete"                               = bdelete ""
      fn ('b':'d':' ':f)                         = bdelete f
      fn ('b':'d':'e':'l':'e':'t':'e':' ':f)     = bdelete f
      fn "bd!"                                   = bdeleteNoW ""
      fn "bdelete!"                              = bdeleteNoW ""
      fn ('b':'d':'!':' ':f)                     = bdeleteNoW f
      fn ('b':'d':'e':'l':'e':'t':'e':'!':' ':f) = bdeleteNoW f
      -- TODO: bd[!] [N]

      -- send just this line through external command /fn/
      fn ('.':'!':f) = do
            ln  <- withBuffer readLnB
            ln' <- runProcessWithInput f ln
            withBuffer $ do moveToSol
                            deleteToEol
                            insertN ln'
                            moveToSol

--    Needs to occur in another buffer
--    fn ('!':f) = runProcessWithInput f []

      fn "reload"     = reloadEditor >> return ()    -- not in vim
      fn "eval"       = withBuffer (regionOfB Document >>= readRegionB) >>= evalE -- not in vim

      fn "redr"       = refreshEditor
      fn "redraw"     = refreshEditor

      fn "u"          = withBuffer undoB
      fn "undo"       = withBuffer undoB
      fn "r"          = withBuffer redoB
      fn "redo"       = withBuffer redoB

      fn "sus"        = suspendEditor
      fn "suspend"    = suspendEditor
      fn "st"         = suspendEditor
      fn "stop"       = suspendEditor

      fn s            = errorEditor $ "The "++show s++ " command is unknown."


------------------------------------------------------------------------

not_implemented :: Char -> YiM ()
not_implemented c = errorEditor $ "Not implemented: " ++ show c

-- ---------------------------------------------------------------------
-- Misc functions

withAllBuffers :: YiM () -> YiM ()
withAllBuffers m = mapM_ (\b -> withEditor (setBuffer b) >> m) =<< readEditor bufferStack

viFileInfo :: YiM ()
viFileInfo =
    do bufInfo <- withBuffer bufInfoB
       msgEditor $ showBufInfo bufInfo
    where
    showBufInfo :: BufferFileInfo -> String
    showBufInfo bufInfo = concat [ show $ bufInfoFileName bufInfo
         , " Line "
         , show $ bufInfoLineNo bufInfo
         , " ["
         , bufInfoPercent bufInfo
         , "]"
         ]


-- | Try to write a file in the manner of vi\/vim
-- Need to catch any exception to avoid losing bindings
viWrite :: YiM ()
viWrite = do
    mf <- withBuffer getfileB
    case mf of
        Nothing -> errorEditor "no file name associate with buffer"
        Just f  -> do
            bufInfo <- withBuffer bufInfoB
            let s   = bufInfoFileName bufInfo
            let msg = msgEditor $ show f ++" "++show s ++ "C written"
            catchJustE ioErrors (fwriteToE f >> msg) (msgEditor . show)


-- | Try to write to a named file in the manner of vi\/vim
viWriteTo :: String -> YiM ()
viWriteTo f = do
    let f' = (takeWhile (/= ' ') . dropWhile (== ' ')) f
    bufInfo <- withBuffer bufInfoB
    let s   = bufInfoFileName bufInfo
    let msg = msgEditor $ show f'++" "++show s ++ "C written"
    catchJustE ioErrors (fwriteToE f' >> msg) (msgEditor . show)

-- | Try to do a substitution
viSub :: [Char] -> YiM ()
viSub cs = do
    let (pat,rep') = break (== '/')  cs
        (rep,opts) = case rep' of
                        []     -> ([],[])
                        (_:ds) -> case break (== '/') ds of
                                    (rep'', [])    -> (rep'', [])
                                    (rep'', (_:fs)) -> (rep'',fs)
    case opts of
        []    -> do_single pat rep
        ['g'] -> do_single pat rep
        _     -> do_single pat rep-- TODO

    where do_single p r = do
                s <- searchAndRepLocal p r
                if not s then errorEditor ("Pattern not found: "++p) else msgClr

-- | Is a delete sequence
isDel :: Char -> Bool
isDel '\BS'        = True
isDel '\127'       = True
isDel c | c == keyBackspace = True
isDel _            = False

-- ---------------------------------------------------------------------
-- | Character ranges
--
delete, enter :: VimProc Char
enter   = oneOf ['\n', '\r']
delete  = oneOf delete'

delete' :: [Char]
delete' =  ['\BS', '\127', keyBackspace ]
