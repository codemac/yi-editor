--
-- Copyright (c) 2005 Don Stewart - http://www.cse.unsw.edu.au/~dons
--
-- This program is free software; you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation; either version 2 of
-- the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
-- General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, write to the Free Software
-- Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
-- 02111-1307, USA.
--

--
-- | An keymap that emulates @mg@, an emacs-like text editor. For more
-- information see <http://www.openbsd.org/cgi-bin/man.cgi?query=mg>
--
-- A quick summary:
--
-- >     ^F     Forward character
-- >     ^B     Backwards character
-- >     ^N     Next line
-- >     ^P     Previous line
-- >     ^A     Start of line
-- >     ^E     End of line
-- >     ^D     delete current character
-- >     ^S     interactive search forward
-- >     ^R     interactive search backwards
-- >     ^O     Open a new line at cursor position
-- >     ^T     transpose characters
-- >     ^U     Repeat next command 4 times (can be cascaded i.e. ^u^u^f will move
-- >            16 characters forward)
-- >
-- >     ^K     kill to end of line (placing into kill buffer)
-- >     ^Y     yank kill buffer into current location
-- >     ^@     set mark
-- >     ^W     kill region (cuts from previously set mark to current location,
-- >            into kill buffer)
-- >     M-W    copy region (into kill buffer)
-- >
-- >     ^V     Next page
-- >     M-V    Previous page
-- >     M-<    start of buffer
-- >     M->    end of buffer
--
-- >     ^X^C   Quit (you will be asked if you want to save files)
-- >     ^X-O   Next window.
-- >     ^X-N   Next window.
-- >     ^X-P   Previous window.
-- >     ^X-U   Undo.
--
-- For more key bindings, type ``M-x describe-bindings''.
--

module Yi.Keymap.Mg (keymap) where

import Yi.Yi         hiding ( keymap )
import Yi.Editor            ( Action )
import Yi.Char
import qualified Yi.Map as M

import Numeric              ( showOct )
import Data.Char            ( ord, chr )
import Data.List            ((\\), isPrefixOf)
import Control.Exception    ( try, evaluate )

------------------------------------------------------------------------

c_ :: Char -> Char
c_ = ctrlLowcase

m_ :: Char -> Char
m_ = setMeta

-- ---------------------------------------------------------------------
-- map extended names to corresponding actions
--
extended2action :: M.Map String Action
extended2action = M.fromList [ (ex,a) | (ex,_,a) <- globalTable ]

--
-- map keystrokes to extended names
--
keys2extended   :: M.Map [Char] String
keys2extended   = M.fromList [ (k,ex) | (ex,ks,_) <- globalTable, k <- ks ]

--
-- map chars to actions
--
keys2action :: [Char] -> Action
keys2action ks | Just ex <- M.lookup ks keys2extended
               , Just a  <- M.lookup ex extended2action  = a
               | otherwise = errorE $ "No binding for "++ show ks

--
-- keystrokes only 1 character long
--
unitKeysList :: [Char]
unitKeysList = [ k | (_,ks,_) <- globalTable, [k] <- ks ]

--
-- C-x mappings
--
ctrlxKeysList :: [Char]
ctrlxKeysList = [ k | (_,ks,_) <- globalTable, ['\^X',k] <- ks ]

--
-- M-O mappings
--
metaoKeysList :: [Char]
metaoKeysList = [ k | (_,ks,_) <- globalTable, [m,k] <- ks, m == m_ 'O' ]

------------------------------------------------------------------------
--
-- global key/action/name map
--
globalTable :: [(String,[String],Action)]
globalTable = [
  ("apropos",
        [[c_ 'h', 'a']],
        errorE "apropos unimplemented"),
  ("backward-char",
        [[c_ 'b'], [m_ 'O', 'D'], [keyLeft]],
        leftE),
  ("backward-kill-word",
        [[m_ '\127']],
        bkillWordE),
  ("backward-word",
        [[m_ 'b']],
        prevWordE),
  ("beginning-of-buffer",
        [[m_ '<']],
        topE),
  ("beginning-of-line",
        [[c_ 'a'], [m_ 'O', 'H']],
        solE),
  ("call-last-kbd-macro",
        [[c_ 'x', 'e']],
        errorE "call-last-kbd-macro unimplemented"),
  ("capitalize-word",
        [[m_ 'c']],
        capitaliseWordE),
  ("copy-region-as-kill",
        [[m_ 'w']],
        errorE "copy-region-as-kill unimplemented"),
  ("delete-backward-char",
        [['\127'], ['\BS'], [keyBackspace]],
        bdeleteE),
  ("delete-blank-lines",
        [[c_ 'x', c_ 'o']],
        mgDeleteBlanks),
  ("delete-char",
        [[c_ 'd']],
        deleteE),
  ("delete-horizontal-space",
        [[m_ '\\']],
        mgDeleteHorizBlanks),
  ("delete-other-windows",
        [[c_ 'x', '1']],
        closeOtherE),
  ("delete-window",
        [[c_ 'x', '0']],
        closeE),
  ("describe-bindings",
        [[c_ 'h', 'b']],
        describeBindings),
  ("describe-key-briefly",
        [[c_ 'h', 'c']],
        msgE "Describe key briefly: " >> cmdlineFocusE >> metaM describeKeymap),
  ("digit-argument",
        [ [m_ d] | d <- ['0' .. '9'] ],
        errorE "digit-argument unimplemented"),
  ("dired",
        [[c_ 'x', 'd']],
        errorE "dired unimplemented"),
  ("downcase-region",
        [[c_ 'x', c_ 'l']],
        errorE "downcase-region unimplemented"),
  ("downcase-word",
        [[m_ 'l']],
        lowercaseWordE),
  ("end-kbd-macro",
        [[c_ 'x', ')']],
        errorE "end-kbd-macro unimplemented"),
  ("end-of-buffer",
        [[m_ '>']],
        botE),
  ("end-of-line",
        [[c_ 'e'], [m_ 'O', 'F']],
        eolE),
  ("enlarge-window",
        [[c_ 'x', '^']],
        enlargeWinE),
  ("shrink-window",             -- not in mg
        [[c_ 'x', 'v']],
        shrinkWinE),
  ("exchange-point-and-mark",
        [[c_ 'x', c_ 'x']],
        errorE "exchange-point-and-mark unimplemented"),
  ("execute-extended-command",
        [[m_ 'x']],
        msgE "M-x " >> cmdlineFocusE >> metaM metaXmap),
  ("fill-paragraph",
        [[m_ 'q']],
        errorE "fill-paragraph unimplemented"),
  ("find-alternate-file",
        [[c_ 'c', c_ 'v']],
        errorE "find-alternate-file unimplemented"),
  ("find-file",
        [[c_ 'x', c_ 'f']],
        msgE "Find file: " >> cmdlineFocusE >> metaM findFileMap),
  ("find-file-other-window",
        [[c_ 'x', '4', c_ 'f']],
        errorE "find-file-other-window unimplemented"),
  ("forward-char",
        [[c_ 'f'], [m_ 'O', 'C'], [keyRight]],
        rightE),
  ("forward-paragraph",
        [[m_ ']']],
        nextNParagraphs 1),
  ("forward-word",
        [[m_ 'f']],
        nextWordE),
  ("goto-line",
        [[c_ 'x', 'g']],
        msgE "Goto line: " >> cmdlineFocusE >> metaM gotoMap),
  ("help-help",
        [[c_ 'h', c_ 'h']],
        errorE "help-help unimplemented"),
  ("insert-file",
        [[c_ 'x', 'i']],
        errorE "insert-file unimplemented"),
  ("isearch-backward",
        [[c_ 'r']],
        errorE "isearch-backward unimplemented"),
  ("isearch-forward",
        [[c_ 's']],
        errorE "isearch-forward unimplemented"),
  ("just-one-space",
        [[m_ ' ']],
        insertE ' '),
  ("keyboard-quit",
        [[c_ 'g'],
         [c_ 'h', c_ 'g'],
         [c_ 'x', c_ 'g'],
         [c_ 'x', '4', c_ 'g'],
         [m_ (c_ 'g')]
        ],
        msgE "Quit" >> metaM defaultKeymap),
  ("kill-buffer",
        [[c_ 'x', 'k']],
        msgE "Kill buffer: " >> cmdlineFocusE >> metaM killBufferMap),
  ("kill-line",
        [[c_ 'k']],
        readRestOfLnE >>= setRegE >> killE),
  ("kill-region",
        [[c_ 'w']],
        errorE "kill-region unimplemented"),
  ("kill-word",
        [[m_ 'd']],
        killWordE),
  ("list-buffers",
        [[c_ 'x', c_ 'b']],
        mgListBuffers),
  ("negative-argument",
        [[m_ '-']],
        errorE "negative-argument unimplemented"),
  ("newline",
        [[c_ 'm']],
        insertE '\n'),
  ("newline-and-indent",
        [],
        errorE "newline-and-indent unimplemented"),
  ("next-line",
        [[c_ 'n'], [m_ 'O', 'B'], [keyDown]], -- doesn't remember goal column
        downE),
  ("not-modified",
        [[m_ '~']],
        errorE "not-modified unimplemented"),
  ("open-line",
        [[c_ 'o']],
        insertE '\n' >> leftE),
  ("other-window",
        [[c_ 'x', 'n'], [c_ 'x', 'o']],
        nextWinE),
  ("previous-line",
        [[c_ 'p'], [m_ 'O', 'A'], [keyUp]],
        upE),
  ("previous-window",
        [[c_ 'x', 'p']],
        prevWinE),
  ("query-replace",
        [[m_ '%']],
        errorE "query-replace unimplemented"),
  ("quoted-insert",
        [[c_ 'q']],
        metaM insertAnyMap),
  ("recenter",
        [[c_ 'l']],
        errorE "recenter unimplemented"),
  ("save-buffer",
        [[c_ 'x', c_ 's']],
        mgWrite),
  ("save-buffers-kill-emacs",
        [[c_ 'x', c_ 'c']],
        quitE), -- should ask to save buffers
  ("save-some-buffers",
        [[c_ 'x', 's']],
        errorE "save-some-buffers unimplemented"),
  ("scroll-down",
        [[m_ '[', '5', '~'], [m_ 'v'], [keyPPage]],
        upScreenE),
  ("scroll-other-window",
        [[m_ (c_ 'v')]],
        errorE "scroll-other-window unimplemented"),
  ("scroll-up",
        [[c_ 'v'], [m_ '[', '6', '~'], [keyNPage]],
        downScreenE),
  ("search-backward",
        [[m_ 'r']],
        errorE "search-backward unimplemented"),
  ("search-forward",
        [[m_ 's']],
        errorE "search-forward unimplemented"),
  ("set-fill-column",
        [[c_ 'x', 'f']],
        errorE "set-fill-column unimplemented"),
  ("set-mark-command",
        [['\NUL']],
        errorE "set-mark-command unimplemented"),
  ("split-window-vertically",
        [[c_ 'x', '2']],
        splitE),
  ("start-kbd-macro",
        [[c_ 'x', '(']],
        errorE "start-kbd-macro unimplemented"),
  ("suspend-emacs",
        [[c_ 'z']],
        suspendE),
  ("switch-to-buffer",
        [[c_ 'x', 'b']],
        errorE "switch-to-buffer unimplemented"),
  ("switch-to-buffer-other-window",
        [[c_ 'x', '4', 'b']],
        errorE "switch-to-buffer-other-window unimplemented"),
  ("transpose-chars",
        [[c_ 't']],
        swapE),
  ("undo",
        [[c_ 'x', 'u'], ['\^_']],
        undoE),
  ("universal-argument",
        [[c_ 'u']],
        errorE "universal-argument unimplemented"),
  ("upcase-region",
        [[c_ 'x', c_ 'u']],
        errorE "upcase-region unimplemented"),
  ("upcase-word",
        [[m_ 'u']],
        uppercaseWordE),
  ("what-cursor-position",
        [[c_ 'x', '=']],
        whatCursorPos),
  ("write-file",
        [[c_ 'x', c_ 'w']],
        msgE "Write file: " >> cmdlineFocusE >> metaM writeFileMap),
  ("yank",
        [[c_ 'y']],
        getRegE >>= mapM_ insertE) ]

------------------------------------------------------------------------

type MgMode = Lexer MgState Action

data MgState = MgState {
        acc    :: String,       -- a line buffer
        prompt :: String        -- current prompt
     }

dfltState :: MgState
dfltState = MgState [] []

defaultKeymap :: [Char] -> [Action]
defaultKeymap = keymap

------------------------------------------------------------------------

keymap :: [Char] -> [Action]
keymap cs = let (actions,_,_) = execLexer mode (cs, dfltState) in actions

------------------------------------------------------------------------

-- default bindings
mode :: MgMode
mode = insert >||< command >||<
       ctrlxSwitch  >||<
       metaSwitch   >||<
       metaOSwitch  >||<
       metaXSwitch

------------------------------------------------------------------------

-- self insertion
insert :: MgMode
insert  = anything `action` \[c] -> Just (insertE c)

-- C- commands
command :: MgMode
command = cmd `action` \[c] -> Just $ if c `elem` unitKeysList
                                        then keys2action [c]
                                        else undefined
        where cmd = alt $ unitKeysList

------------------------------------------------------------------------

-- switch to ctrl-X submap
ctrlxSwitch :: MgMode
ctrlxSwitch = char '\^X'
        `meta` \_ st -> (with (msgE "C-x-"), st, Just ctrlxMode)

-- ctrl x submap
ctrlxMode :: MgMode
ctrlxMode = cmd
        `meta` \[c] st -> (with (msgClrE >> f c), st, Just mode)
        where
            cmd = alt ctrlxKeysList
            f c = if c `elem` ctrlxKeysList
                    then keys2action ['\^X',c]
                    else undefined

------------------------------------------------------------------------
--
-- on escape, we'd also like to switch to M- mode
--

-- switch to meta mode
metaSwitch :: MgMode
metaSwitch = char '\ESC'        -- hitting ESC also triggers a meta char
        `meta` \_ st -> (with (msgE "ESC-"), st,  Just metaMode)

--
-- a fake mode. really just looking up the binding for: m_ c
--
metaMode :: MgMode
metaMode = alt ['\0' .. '\255']       -- not quite right
        `meta` \[c] st -> (Just (Right (msgClrE >> f c)), st, Just mode) -- and leave
        where
            f c = if (m_ c) `elem` unitKeysList
                    then keys2action [m_ c]
                    else undefined

------------------------------------------------------------------------

-- switch to meta O mode
metaOSwitch :: MgMode
metaOSwitch = char (m_ 'O')
        `meta` \_ st -> (Just (Right (msgE "ESC-O-")), st,  Just metaOMode)

metaOMode :: MgMode
metaOMode = cmd
        `meta` \[c] st -> (Just (Right (msgClrE >> f c)), st, Just mode)
        where
            cmd = alt metaoKeysList
            f c = if c `elem` metaoKeysList
                      then keys2action [m_ 'O',c]
                      else undefined

-- ---------------------------------------------------------------------
-- build a generic line buffer editor, given a mode to transition to
--
editInsert :: MgMode -> MgMode
editInsert m = anyButDelNlArrow
        `meta` \[c] st -> (with (msgE (prompt st ++ (reverse (acc st)) ++ [c]))
                          , st{acc=c:acc st} , Just m)
    where anyButDelNlArrow = alt $ any' \\ (enter' ++ delete' ++ ['\ESC',keyUp,keyDown])

editDelete :: MgMode -> MgMode
editDelete m = delete
    `meta` \_ st ->
        let cs' = case acc st of
                        []    -> []
                        (_:xs) -> xs
        in (with (msgE (prompt st ++ reverse cs')), st{acc=cs'}, Just m)

editEscape :: MgMode
editEscape = char '\^G'
    `meta` \_ _ -> (with (cmdlineUnFocusE >> msgE "Quit"), dfltState, Just mode)

--
-- and build a generic keymap
--
mkKeymap :: MgMode -> MgState -> ([Char] -> [Action])
mkKeymap m st = \cs -> let (actions,_,_) = execLexer m (cs, st) in actions

--
-- and a default state
--
mkPromptState :: String -> MgState
mkPromptState p = MgState { prompt = p, acc = [] }

------------------------------------------------------------------------

-- execute an extended command
metaXSwitch :: MgMode
metaXSwitch = (char (m_ 'x') >|< char (m_ 'X'))
        `meta` \_ _ -> (with (msgE "M-x " >> cmdlineFocusE)
                       , metaXState
                       , Just metaXMode)

--
-- a line buffer mode, where we ultimately map the command back to a
-- keystroke, and execute that.
--
metaXState :: MgState
metaXState = mkPromptState "M-x "

metaXmap :: [Char] -> [Action]
metaXmap = mkKeymap metaXMode metaXState

metaXMode :: MgMode
metaXMode = (editInsert metaXMode) >||< (editDelete metaXMode) >||<
            editEscape >||< metaXEval

-- | M-x mode, evaluate a string entered after M-x
metaXEval :: MgMode
metaXEval = enter
    `meta` \_ MgState{acc=cca} ->
        let cmd = reverse cca
        in case M.lookup cmd extended2action of
                Nothing -> (with $ msgE "[No match]" >> cmdlineUnFocusE
                           , MgState [] [], Just mode)
                Just a  -> (with (cmdlineUnFocusE  >> msgClrE >> a)
                           , MgState [] [], Just mode)

-- metaXTab :: MgMode

------------------------------------------------------------------------

describeKeyMode :: MgMode
describeKeyMode = describeChar

describeKeymap :: [Char] -> [Action]
describeKeymap = mkKeymap describeKeyMode describeKeyState

describeKeyState :: MgState
describeKeyState = mkPromptState "Describe key briefly: "

describeChar :: MgMode
describeChar = anything
    `meta` \[c] st ->
        let acc' = c : acc st
            keys = reverse acc'
        in case M.lookup keys keys2extended of
            Just ex -> (with $ (msgE $ (printable keys) ++ " runs the command " ++ ex)
                                 >> cmdlineUnFocusE
                       ,dfltState, Just mode)
            Nothing ->
                -- only continue if this is the prefix of something in the table
                if any (isPrefixOf keys) (M.keys keys2extended)
                   then (with $ msgE (prompt st ++ keys)
                        ,st{acc=acc'}, Just describeKeyMode)
                   else (with $ (msgE $ printable keys ++ " is not bound to any function")
                                >> cmdlineUnFocusE
                        ,dfltState, Just mode)

------------------------------------------------------------------------
-- Reading a filename, to open a buffer
--
findFileMap :: [Char] -> [Action]
findFileMap = mkKeymap findFileMode findFileState

findFileState :: MgState
findFileState = mkPromptState "Find file: "

findFileMode :: MgMode
findFileMode = (editInsert findFileMode) >||<
               (editDelete findFileMode) >||<
               editEscape >||< findFileEval

findFileEval :: MgMode
findFileEval = enter
        `meta` \_ MgState{acc=cca} ->
        (with (do fnewE (reverse cca)
                  (_,s,_,_,_,_) <- bufInfoE
                  msgE $ "(Read "++show s++" bytes)"
                  cmdlineUnFocusE)
        , MgState [] [], Just mode )

-- ---------------------------------------------------------------------
-- Writing a file
--
writeFileMap  :: [Char] -> [Action]
writeFileMap = mkKeymap writeFileMode writeFileState

writeFileState :: MgState
writeFileState = mkPromptState "Write file: "

writeFileMode :: MgMode
writeFileMode = (editInsert writeFileMode) >||<
                (editDelete writeFileMode) >||<
                editEscape >||< writeFileEval

writeFileEval :: MgMode
writeFileEval = enter
        `meta` \_ MgState{acc=cca} ->
        let f = reverse cca
        in (with (do fwriteToE f
                     msgE $ "Wrote "++f
                     cmdlineUnFocusE)
           ,MgState [] [], Just mode )

-- ---------------------------------------------------------------------
-- Killing a buffer by name
killBufferMap :: [Char] -> [Action]
killBufferMap = mkKeymap killBufferMode killBufferState

killBufferState :: MgState
killBufferState = mkPromptState "Kill buffer: "

killBufferMode :: MgMode
killBufferMode = (editInsert killBufferMode) >||<
                 (editDelete killBufferMode) >||<
                 editEscape >||< killBufferEval

killBufferEval :: MgMode
killBufferEval = enter
        `meta` \_ MgState{acc=cca} ->
        let buf = reverse cca
        in (with (closeBufferE buf >> cmdlineUnFocusE)
           ,MgState [] [], Just mode )

-- ---------------------------------------------------------------------
-- Goto a line
--
gotoMap  :: [Char] -> [Action]
gotoMap = mkKeymap gotoMode gotoState

gotoState :: MgState
gotoState = mkPromptState "Goto line: "

gotoMode :: MgMode
gotoMode = (editInsert gotoMode) >||<
           (editDelete gotoMode) >||< editEscape >||< gotoEval

gotoEval :: MgMode
gotoEval = enter
        `meta` \_ MgState{acc=cca} ->
        let l = reverse cca
        in (with ((do
                i <- try . evaluate . read $ l
                case i of Left _   -> errorE "Invalid number"
                          Right i' -> gotoLnE i') >> cmdlineUnFocusE)
           ,MgState [] [], Just mode )

-- ---------------------------------------------------------------------
-- insert the first character, then switch back to normal mode
--
insertAnyMap :: [Char] -> [Action]
insertAnyMap = mkKeymap insertAnyMode dfltState

insertAnyMode :: MgMode
insertAnyMode = alt ['\0' .. '\255']
        `meta` \[c] st -> (with (insertE c), st, Just mode)

------------------------------------------------------------------------
-- translate a string into the emacs encoding of that string
--
printable :: String -> String
printable = dropSpace . printable'
    where
        printable' ('\ESC':a:ta) = "M-" ++ [a] ++ printable' ta
        printable' ('\ESC':ta) = "ESC " ++ printable' ta
        printable' (a:ta)
                | ord a < 32
                = "C-" ++ [chr (ord a + 96)] ++ " " ++ printable' ta
                | isMeta a
                = "M-" ++ printable' (clrMeta a:ta)
                | ord a >= 127
                = bigChar a ++ " " ++ printable' ta
                | otherwise  = [a, ' '] ++ printable' ta

        printable' [] = []

        bigChar c
                | c == keyDown  = "<down"
                | c == keyUp    = "<up>"
                | c == keyLeft  = "<left>"
                | c == keyRight = "<right>"
                | c == keyNPage = "<pagedown>"
                | c == keyPPage = "<pageup>"
                | c == '\127'   = "<delete>"
                | otherwise     = show c

------------------------------------------------------------------------
-- Mg-specific actions

whatCursorPos :: Action
whatCursorPos = do
        (_,_,ln,col,pt,pct) <- bufInfoE
        c <- readE
        msgE $ "Char: "++[c]++" (0"++showOct (ord c) ""++
                ")  point="++show pt++
                "("++pct++
                ")  line="++show ln++
                "  row=? col="++ show col

describeBindings :: Action
describeBindings = newBufferE "*help*" s
    where
      s = unlines [ let p = printable k
                    in p ++ replicate (17 - length p) ' ' ++ ex
                  | (ex,ks,_) <- globalTable
                  , k         <- ks ]

-- bit of a hack, unfortunately
mgListBuffers :: Action
mgListBuffers = do
        closeBufferE name   -- close any previous buffer list buffer
        newBufferE name []  -- new empty one
        bs  <- listBuffersE -- get current list
        closeBufferE name   -- close temporary one
        newBufferE name (f bs) -- and finally display current one
    where
        name = "*Buffer List*"
        f bs = unlines [ "  "++(show i)++"\t"++(show n) | (n,i) <- bs ]

-- save a file in the style of Mg
mgWrite :: Action
mgWrite = do
        u <- isUnchangedE      -- just  the current buffer
        if u then msgE "(No changes need to be saved)"
             else do
                mf <- fileNameE
                case mf of
                        Nothing -> errorE "No filename connected to this buffer"
                        Just f  -> fwriteE >> msgE ("Wrote " ++ f)

--
-- delete all blank lines from this point
mgDeleteBlanks :: Action
mgDeleteBlanks = do
        p <- getPointE
        moveWhileE (== '\n') Right
        q <- getPointE
        gotoPointE p
        deleteNE (q - p)

-- not quite right, as it will delete, even if no blanks
mgDeleteHorizBlanks :: Action
mgDeleteHorizBlanks = do
        p <- getPointE
        moveWhileE (\c -> c == ' ' || c == '\t') Right
        q <- getPointE
        gotoPointE p
        deleteNE (q - p)

------------------------------------------------------------------------
--
-- some regular expressions

any', enter', delete' :: [Char]
enter'   = ['\n', '\r']
delete'  = ['\BS', '\127', keyBackspace ]
any'     = ['\0' .. '\255']

delete, enter, anything :: Regexp MgState Action
delete  = alt delete'
enter   = alt enter'
anything  = alt any'
