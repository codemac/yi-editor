-- -*- haskell -*- 
--
-- Simple syntax highlighting for Latex source files
--
-- This is not intended to be a lexical analyser for
-- latex, merely good enough to provide some syntax
-- highlighting for latex source files.
--

{
{-# OPTIONS -w  #-}
module Yi.Lexer.Latex ( initState, alexScanToken, Token(..), HlState ) where
import Yi.Lexer.Alex
import Yi.Style
}

$special   = [\[\]\{\}\$\\\%\(\)\ ]
$textChar = [~$special $white]
$idchar = [a-zA-Z 0-9_\-]

@reservedid = begin|end|newcommand
@ident = $idchar+
@text = $textChar+

haskell :-

 "%"\-*[^\n]*                                { c $ Comment }
 $special                                    { cs $ \(c:_) -> Special c }
 \\"begin{"@ident"}"                         { cs $ \s -> Begin (drop 6 s) }
 \\"end{"@ident"}"                           { cs $ \s -> End (drop 4 s) }
 \\$special                                  { cs $ \(_:cs) -> Command cs }
 \\newcommand                                { c $ NewCommand }
 \\@ident                                    { cs $ \(_:cs) -> Command cs }
 @text                                       { c $ Text }


{

data Token = Comment | Text | Special !Char | Command !String | Begin !String | End !String | NewCommand  
  deriving (Eq, Show, Ord)

type HlState = Int

{- See Haskell.x which uses this to say whether we are in a
   comment (perhaps a nested comment) or not.
-}
stateToInit x = 0

initState :: HlState
initState = 0


#include "common.hsinc"
}
