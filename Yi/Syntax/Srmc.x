-- -*- haskell -*- 
--
--  Simple syntax highlighting for srmc source.
--  Also to be used for pepa source files since pepa
--  is a subset of srmc.
--  I also believe that this makes a reasonable example
--  for new syntax files
--

{
{-# OPTIONS -w  #-}
module Yi.Syntax.Srmc ( highlighter ) where
{- Standard Library Modules Imported -}
import qualified Data.ByteString.Char8
import qualified Data.ByteString.Lazy.Char8 as LB
import qualified Yi.FingerString
{- External Library Modules Imported -}
{- Local Modules Imported -}
import qualified Yi.Syntax
import Yi.Style
  ( Style             ( .. )
  , defaultStyle
  , commentStyle
  , lineCommentStyle
  , keywordStyle
  , operatorStyle
  , upperIdStyle
  , stringStyle
  , numberStyle
  )
{- End of Module Imports -}

}

$whitechar = [\ \t\n\r\f\v]
$special   = [\(\)\,\;\[\]\`\{\}]

$ascdigit  = 0-9
$unidigit  = [] -- TODO
$digit     = [$ascdigit $unidigit]

$ascsymbol  = [\!\#\$\%\&\*\+\.\/\<\=\>\?\@\\\^\|\-\~]
$unisymbol  = [] -- TODO
$pepasymbol = [\;\.\,\+=\<\>]
$symbol     = [$pepasymbol]

$large     = [A-Z \xc0-\xd6 \xd8-\xde]
$small     = [a-z \xdf-\xf6 \xf8-\xff \_]
$alpha     = [$small $large]

$graphic   = [$small $large $symbol $digit $special \:\"\']

$octit     = 0-7
$hexit     = [0-9 A-F a-f]
$idchar    = [$alpha $digit \']
$symchar   = [$symbol]
$nl        = [\n\r]

@reservedid = Stop|infty

@reservedop = "&&" | "||"

@varid  = $small $idchar*
@conid  = $large $idchar*
@varsym = $symbol $symchar*
@consym = \: $symchar*

@decimal     = $digit+
@double      = $digit+ \. $digit+
@octal       = $octit+
@hexadecimal = $hexit+
@exponent    = [eE] [\-\+] @decimal

$cntrl   = [$large \@\[\\\]\^\_]
@ascii   = \^ $cntrl | NUL | SOH | STX | ETX | EOT | ENQ | ACK
         | BEL | BS | HT | LF | VT | FF | CR | SO | SI | DLE
         | DC1 | DC2 | DC3 | DC4 | NAK | SYN | ETB | CAN | EM
         | SUB | ESC | FS | GS | RS | US | SP | DEL
$charesc = [abfnrtv\\\"\'\&]
@escape  = \\ ($charesc | @ascii | @decimal | o @octal | x @hexadecimal)
@gap     = \\ $whitechar+ \\
@string  = $graphic # [\"\\] | " " | @escape | @gap

haskell :-

<0> $white+                                     { c defaultStyle } -- whitespace


<0> {
  "%"\-*[^\n]*                                  { c commentStyle }
  "//"\-*[^\n]*                                 { c commentStyle }

 -- $special                                       { c defaultStyle }

 @reservedid                                    { c keywordStyle }

 @varid                                         { c stringStyle }
 @conid                                         { c upperIdStyle }

 @reservedop                                    { c operatorStyle }
 @varsym                                        { c operatorStyle }

 @decimal 
  | @double
  | 0[oO] @octal
  | 0[xX] @hexadecimal                          { c numberStyle }

 @decimal \. @decimal @exponent?
  | @decimal @exponent                          { c defaultStyle }

 .                                              { c defaultStyle }
}

{

type HlState = Int

{- 
  See Haskell.x which uses this to say whether we are in a
  comment (perhaps a nested comment) or not.
-}
stateToInit x = 0

initState = 0

#include "alex.hsinc"
}
