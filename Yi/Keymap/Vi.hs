-- Copyright (c) 2004, 2008 Don Stewart - http://www.cse.unsw.edu.au/~dons

-- | Vi keymap for Yi.
-- Based on version 1.79 (7\/14\/97) of nex\/nvi
--
-- The goal is strict vi emulation

module Yi.Keymap.Vi ( keymap, ViMode ) where

import Yi.Yi
import Yi.Editor
-- import Yi.UI as UI
import Yi.History

import Prelude       hiding ( any, error )

import Data.Char
import Data.List            ( (\\) )

import Control.Arrow ((+++))
import Control.Exception    ( ioErrors, try, evaluate )

import Control.Monad.State



-- ---------------------------------------------------------------------

type ViMode = ViProc ()

type ViProc a = (Interact Char) a

--
-- | Top level. Lazily consume all the input, generating a list of
-- actions, which then need to be forced
--
-- NB . if there is a (bad) exception, we'll lose any new bindings.. iorefs?
--    . also, maybe we shouldn't refresh automatically?
--
keymap :: Keymap
keymap = do write $ setWindowFillE '~'
            runVi cmd_mode

runVi :: ViMode -> Keymap
runVi = comap eventToChar

------------------------------------------------------------------------

-- The vi lexer is divided into several parts, roughly corresponding
-- to the different modes of vi. Each mode is in turn broken up into
-- separate lexers for each phase of key input in that mode.

-- | command mode consits of simple commands that take a count arg - the
-- count is stored in the lexer state. also the replace cmd, which
-- consumes one char of input, and commands that switch modes.
cmd_mode :: ViMode
cmd_mode = choice [cmd_eval,eval cmd_move,cmd2other,cmd_op]

eval :: ViProc Action -> ViMode
eval p = do a <- p; write a

--
-- | insert mode is either insertion actions, or the meta \ESC action
--
ins_mode :: ViMode
ins_mode = many' ins_char >> event '\ESC' >> return ()

--
-- | replace mode is like insert, except it performs writes, not inserts
--
rep_mode :: ViMode
rep_mode = many' rep_char >> event '\ESC' >> return ()

------------------------------------------------------------------------
--
-- A parser to accumulate digits.
-- typically what is needed for integer repetition arguments to commands
--
-- ToDo don't handle 0 properly
--
count :: ViProc (Maybe Int)
count = option Nothing (many1' (satisfy isDigit) >>= return . Just . read)

-- ---------------------------------------------------------------------
-- | Movement commands
--
-- The may be invoked directly, or sometimes as arguments to other
-- /operator/ commands (like d).
--
cmd_move :: ViProc Action
cmd_move = do
  cnt <- count
  let x = maybe 1 id cnt
  choice [event c >> return (a x) | (c,a) <- moveCmdFM] +++
   choice [do event c; c' <- anyButEsc; return (a x c') | (c,a) <- move2CmdFM] +++
   (do event 'G'; return $ case cnt of
                            Nothing -> botE >> moveToSol
                            Just n  -> gotoLn n)


--
-- movement commands
--
moveCmdFM :: [(Char, Int -> Action)]
moveCmdFM =
-- left/right
    [('h',          left)
    ,('\^H',        left)
    ,(keyBackspace, left)
    ,('\BS',        left)
    ,('l',          right)
    ,(' ',          right)
    ,(keyHome,      const firstNonSpaceE)   -- vim does moveToSol
    ,('^',          const firstNonSpaceE)
    ,('$',          const moveToEol)
    ,('|',          \i -> moveToSol >> rightOrEolE (i-1))

-- up/down
    ,('k',          up)
    ,(keyUp,        up)
    ,('\^P',        up)
    ,('j',          down)
    ,(keyDown,      down)
    ,('\^J',        down)
    ,('\^L',        const refreshEditor)
    ,('\^N',        down)
    ,('\r',         down)

-- words
    -- ToDo these aren't quite right, but are nice and simple
    ,('w',          \i -> replicateM_ i $ do
                            moveWhileE (isAlphaNum)      GoRight
                            moveWhileE (not.isAlphaNum)  GoRight )

    ,('b',          \i -> replicateM_ i $ do
                            moveWhileE (isAlphaNum)      GoLeft
                            moveWhileE (not.isAlphaNum)  GoLeft )

-- text
    ,('{',          prevNParagraphs)
    ,('}',          nextNParagraphs)

-- misc
    ,('H',          \i -> downFromTosB (i - 1))
    ,('M',          const middleB)
    ,('L',          \i -> upFromBosB (i - 1))

-- bogus entry
    ,('G',          const (return ()))
    ]
    where
        left  i = leftOrSolE i
        right i = rightOrEolE i
        up    i = if i > 100 then gotoLnFromE (-i) else replicateM_ i (execB Move VLine Backward)
        down  i = if i > 100 then gotoLnFromE i    else replicateM_ i (execB Move VLine Forward)

--
-- more movement commands. these ones are paramaterised by a character
-- to find in the buffer.
--
move2CmdFM :: [(Char, Int -> Char -> Action)]
move2CmdFM =
    [('f',  \i c -> replicateM_ i $ rightB >> moveWhileE (/= c) GoRight)
    ,('F',  \i c -> replicateM_ i $ leftB  >> moveWhileE (/= c) GoLeft)
    ,('t',  \i c -> replicateM_ i $ rightB >> moveWhileE (/= c) GoRight >> leftB)
    ,('T',  \i c -> replicateM_ i $ leftB  >> moveWhileE (/= c) GoLeft  >> rightB)
    ]

--
-- | Other command mode functions
--
cmd_eval :: ViMode
cmd_eval = do
   cnt <- count
   let i = maybe 1 id cnt
   choice [event c >> write (a i) | (c,a) <- cmdCmdFM ] +++
    (do event 'r'; c <- anyButEscOrDel; write (writeE c)) +++
    (events ">>" >> write (do replicateM_ i $ moveToSol >> mapM_ insertN "    "
                              firstNonSpaceE)) +++
    (events "<<" >> write (do moveToSol
                              replicateM_ i $
                                replicateM_ 4 $
                                    readB >>= \k ->
                                        when (isSpace k) deleteN 1
                              firstNonSpaceE)) +++
    (events "ZZ" >> write (viWrite >> quitEditor))

   where anyButEscOrDel = oneOf $ any' \\ ('\ESC':delete')

--
-- cmd mode commands
--
cmdCmdFM :: [(Char, Int -> Action)]
cmdCmdFM =
    [('\^B',    upScreensB)
    ,('\^F',    downScreensB)
    ,('\^G',    const viFileInfo)
    ,('\^W',    const nextWinE)
    ,('\^Z',    const suspendEditor)
    ,('D',      killLineE)
    ,('J',      const (moveToEol >> deleteN 1))    -- the "\n"
    ,('n',      const (doSearch Nothing [] GoRight))

    ,('X',      \i -> do p <- getSelectionMarkPointB
                         leftOrSolE i
                         q <- getSelectionMarkPointB -- how far did we really move?
                         when (p-q > 0) $ deleteNE (p-q) )

    ,('x',      \i -> do p <- getSelectionMarkPointB -- not handling eol properly
                         rightOrEolE i
                         q <- getSelectionMarkPointB
                         gotoPointE p
                         when (q-p > 0) $ deleteNE (q-p) )

    ,('p',      (\_ -> getRegE >>= \s ->
                        moveToEol >> insertN '\n' >>
                            mapM_ insertN s >> moveToSol)) -- ToDo insertNE

    ,(keyPPage, upScreensB)
    ,(keyNPage, downScreensB)
    ,(keyLeft,  leftOrSolE)          -- not really vi, but fun
    ,(keyRight, rightOrEolE)
    ]

--
-- | So-called 'operators', which take movement actions as arguments.
--
-- How do we achive this? We look for the known operator chars
-- (op_char), followed by digits and one of the known movement commands.
-- We then consult the lexer table with digits++move_char, to see what
-- movement commands they correspond to. We then return an action that
-- performs the movement, and then the operator. For example, we 'd'
-- command stores the current point, does a movement, then deletes from
-- the old to the new point.
--
-- We thus elegantly achieve things like 2d4j (2 * delete down 4 times)
-- Lazy lexers - you know we're right (tm).
--
cmd_op :: ViMode
cmd_op = do
  cnt <- count
  let i = maybe 1 id cnt
  choice $ [events "dd" >> write (moveToSol >> killE >> deleteN 1),
            events "yy" >> write (readLnE >>= setRegE)] ++
           [do event c; m <- cmd_move; write (a i m) | (c,a) <- opCmdFM]
    where
        -- | operator (i.e. movement-parameterised) actions
        opCmdFM :: [(Char,Int -> Action -> Action)]
        opCmdFM =
            [('d', \i m -> replicateM_ i $ do
                              (p,q) <- withPointMove m
                              deleteNE (max 0 (abs (q - p) + 1))  -- inclusive
             ),
             ('y', \_ m -> do (p,q) <- withPointMove m
                              s <- (if p < q then readNM p q else readNM q p)
                              setRegE s -- ToDo registers not global.
             )
            ,('~', const invertCase) -- not right.
            ]

        -- invert the case of range described by movement @m@
        -- could take 90s on a 64M file.
        invertCase m = do
            (p,q) <- withPointMove m
            mapRangeE (min p q) (max p q) $ \c ->
                if isUpper c then toLower c else toUpper c

        --
        -- A strange, useful action. Save the current point, move to
        -- some xlocation specified by the sequence @m@, then return.
        -- Return the current, and remote point.
        --
        withPointMove :: Action -> EditorM (Int,Int)
        withPointMove m = do p <- getSelectionMarkPointB
                             m
                             q <- getSelectionMarkPointB
                             when (p < q) $ gotoPointE p
                             return (p,q)


--
-- | Switch to another vi mode.
--
-- These commands transfer control to another
-- process. Some of these commands also perform an action before switching.
--
cmd2other :: ViMode
cmd2other = do c <- modeSwitchChar
               case c of
                 ':' -> ex_mode ":"
                 'R' -> rep_mode
                 'i' -> ins_mode
                 'I' -> write moveToSol >> ins_mode
                 'a' -> write (rightOrEolE 1) >> ins_mode
                 'A' -> write moveToEol >> ins_mode
                 'o' -> write (moveToEol >> insertN '\n') >> ins_mode
                 'O' -> write (moveToSol >> insertN '\n' >> (execB Move VLine Backward)) >> ins_mode
                 'c' -> write (not_implemented 'c') >> ins_mode
                 'C' -> write (killLineE) >> ins_mode
                 'S' -> write (moveToSol >> readLnE >>= setRegE >> killE) >> ins_mode

                 '/' -> ex_mode "/"

                 '\ESC'-> write msgClr

                 s   -> write $ errorEditor ("The "++show s++" command is unknown.")


    where modeSwitchChar = oneOf ":RiIaAoOcCS/?\ESC"

-- ---------------------------------------------------------------------
-- | vi insert mode
--
ins_char :: ViMode
ins_char = write . fn =<< anyButEsc
    where fn c = case c of
                    k | isDel k       -> leftB >> deleteN 1
                      | k == keyPPage -> upScreenB
                      | k == keyNPage -> downScreenB
                      | k == '\t'     -> mapM_ insertN "    " -- XXX
                    _ -> insertN c


-- ---------------------------------------------------------------------
-- | vi replace mode
--
-- To quote vi:
--  In Replace mode, one character in the line is deleted for every character
--  you type.  If there is no character to delete (at the end of the line), the
--  typed character is appended (as in Insert mode).  Thus the number of
--  characters in a line stays the same until you get to the end of the line.
--  If a <NL> is typed, a line break is inserted and no character is deleted.
--
-- ToDo implement the undo features
--

rep_char :: ViMode
rep_char = write . fn =<< anyButEsc
    where fn c = case c of
                    k | isDel k       -> leftB >> deleteN 1
                      | k == keyPPage -> upScreenB
                      | k == keyNPage -> downScreenB
                    '\t' -> mapM_ insertN "    " -- XXX
                    '\r' -> insertN '\n'
                    _ -> do e <- atEolE
                            if e then insertN c else writeE c >> rightB

-- ---------------------------------------------------------------------
-- Ex mode. We also process regex searching mode here.

spawn_ex_buffer :: String -> Action
spawn_ex_buffer prompt = do
  initialBuffer <- getBuffer
  Just initialWindow <- getWindow
  -- The above ensures that the action is performed on the buffer that originated the minibuffer.
  let closeMinibuffer = do b <- getBuffer; closeWindow; deleteBuffer b
      anyButDelNlArrow = oneOf $ any' \\ (enter' ++ delete' ++ ['\ESC',keyUp,keyDown])
      ex_buffer_finish = do
        historyFinish
        lineString <- readAllE
        closeMinibuffer
--        UI.setWindow initialWindow
        switchToBufferE initialBuffer
        ex_eval (head prompt : lineString)
      ex_process :: ViMode
      ex_process =
          choice [do c <- anyButDelNlArrow; write $ insertNE [c],
                  do enter; write ex_buffer_finish,
                  do event '\ESC'; write closeMinibuffer,
                  do delete; write bdeleteB,
                  do event keyUp; write historyUp,
                  do event keyDown; write historyDown]
  historyStart
  spawnMinibufferE prompt (const $ runVi $ forever ex_process) (return ())


ex_mode :: String -> ViMode
ex_mode = write . spawn_ex_buffer

-- | eval an ex command to an Action, also appends to the ex history
ex_eval :: String -> Action
ex_eval cmd = do
  case cmd of
        -- regex searching
          ('/':pat) -> doSearch (Just pat) [] GoRight

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
          [] -> (return ())

    where
      fn ""           = msgClr

      fn s@(c:_) | isDigit c = do
        e <- lift $ try $ evaluate $ read s
        case e of Left _ -> errorEditor $ "The " ++show s++ " command is unknown."
                  Right lineNum -> gotoLn lineNum

      fn "w"          = viWrite
      fn ('w':' ':f)  = viWriteTo f
      fn "q"          = do
            b <- isUnchangedB
            if b then closeWindow
                 else errorEditor $ "File modified since last complete write; "++
                               "write or use ! to override."
      fn "q!"         = closeWindow
      fn "$"          = botE
      fn "wq"         = viWrite >> closeWindow
      fn "n"          = nextBufW
      fn "p"          = prevBufW
      fn ('s':'p':_)  = splitE
      fn ('e':' ':f)  = fnewE f
      fn ('s':'/':cs) = viSub cs

      fn "reboot"     = rebootE     -- !
      fn "reload"     = reloadEditor >> return ()     -- !

      fn s            = errorEditor $ "The "++show s++ " command is unknown."


------------------------------------------------------------------------

not_implemented :: Char -> Action
not_implemented c = errorEditor $ "Not implemented: " ++ show c

-- ---------------------------------------------------------------------
-- Misc functions

viFileInfo :: Action
viFileInfo =
    do bufInfo <- bufInfoB
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
viWrite :: Action
viWrite = do
    mf <- fileNameE
    case mf of
        Nothing -> errorEditor "no file name associate with buffer"
        Just f  -> do
            bufInfo <- bufInfoB
            let s   = bufInfoFileName bufInfo
            let msg = msgEditor $ show f ++" "++show s ++ "C written"
            catchJustE ioErrors (fwriteToE f >> msg) (msgEditor . show)

-- | Try to write to a named file in the manner of vi\/vim
viWriteTo :: String -> Action
viWriteTo f = do
    let f' = (takeWhile (/= ' ') . dropWhile (== ' ')) f
    bufInfo <- bufInfoB
    let s   = bufInfoFileName bufInfo
    let msg = msgEditor $ show f'++" "++show s ++ "C written"
    catchJustE ioErrors (fwriteToE f' >> msg) (msgEditor . show)


-- | Try to do a substitution
viSub :: [Char] -> Action
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

{-
          -- inefficient. we recompile the regex each time.
          -- stupido
          do_line   p r = do
                let loop i = do s <- searchAndRepLocal p r
                                if s then loop (i+1) else return i
                s <- loop (0 :: Int)
                if s == 0 then msgEditor ("Pattern not found: "++p) else msgClr
-}

-- ---------------------------------------------------------------------
-- | Handle delete chars in a string
--
{-
clean :: [Char] -> [Char]
clean (_:c:cs) | isDel c = clean cs
clean (c:cs)   | isDel c = clean cs
clean (c:cs) = c : clean cs
clean [] = []
-}

-- | Is a delete sequence
isDel :: Char -> Bool
isDel '\BS'        = True
isDel '\127'       = True
isDel c | c == keyBackspace = True
isDel _            = False

-- ---------------------------------------------------------------------
-- | character ranges
--
delete, enter, anyButEsc :: ViProc Char
enter   = oneOf enter'
delete  = oneOf delete'
anyButEsc = oneOf $ (keyBackspace : any' ++ cursc') \\ ['\ESC']

enter', any', delete' :: [Char]
enter'   = ['\n', '\r']
delete'  = ['\BS', '\127', keyBackspace ]
any'     = ['\0' .. '\255']

cursc' :: [Char]
cursc'   = [keyPPage, keyNPage, keyLeft, keyRight, keyDown, keyUp]
