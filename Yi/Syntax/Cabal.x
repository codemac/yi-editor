-- -*- haskell -*- 
--
-- Lexical syntax for illiterate Haskell 98.
--
-- (c) Simon Marlow 2003, with the caveat that much of this is
-- translated directly from the syntax in the Haskell 98 report.
--

{
{-# OPTIONS -w  #-}
module Yi.Syntax.Cabal
  ( highlighter ) 
where

import qualified Data.ByteString.Char8
import qualified Yi.FingerString
import qualified Data.ByteString.Lazy.Char8 as LB
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
}

$whitechar = [\ \t\n\r\f\v]
$special   = [\(\)\,\;\[\]\`\{\}]

$ascdigit  = 0-9
$unidigit  = [] -- TODO
$digit     = [$ascdigit $unidigit]

$ascsymbol = [\!\#\$\%\&\*\+\.\/\<\=\>\?\@\\\^\|\-\~]
$unisymbol = [] -- TODO
$symbol    = [$ascsymbol $unisymbol] # [$special \_\:\"\']

$large     = [A-Z \xc0-\xd6 \xd8-\xde]
$small     = [a-z \xdf-\xf6 \xf8-\xff \_]
$alpha     = [$small $large]

$graphic   = [$small $large $symbol $digit $special \:\"\']

$octit     = 0-7
$hexit     = [0-9 A-F a-f]
$idchar    = [$alpha $digit \']
$symchar   = [$symbol \:]
$nl        = [\n\r]

@reservedid = 
  GPL
  |LGPL
  |BSD3
  |BSD4
  |PublicDomain
  |AllRightsReserved
  |OtherLicense
  |if
  |flag

@fieldid =
  [Nn]ame
  |[Vv]ersion
  |[Cc]abal\-Version
  |[Cc]abal\-version
  |[Dd]escription
  |[Ll]icense
  |[Ll]icense\-file
  |[Aa]uthor
  |[Mm]aintainer
  |[Bb]uild\-Depends
  |[Bb]uild\-depends
  |[Ee]xecutable
  |[Mm]ain\-Is
  |[Mm]ain\-is
  |[Oo]ther\-Modules
  |[Oo]ther\-modules
  |[Gg]hc\-Options
  |[Gg]hc\-options
  |[Cc]opyright
  |[Hh]omepage
  |[Ss]ynopsis
  |[Ee]xposed\-Modules
  |[Ee]xposed\-modules
  |[Ii]nclude\-Dirs
  |[Ii]nclude\-dirs
  |[Cc]\-Sources
  |[Cc]\-sources
  |[Ee]xtra\-Libraries
  |[Ee]xtra\-libraries
  |[Ee]xtensions
  |[Cc]ategory
  |[Bb]uildabl
  |[Ee]xtra\-[Ss]ource\-[Ff]iles

@reservedop =
        ">" | ">=" | "<" | "<="

@varid  = $small $idchar*
@conid  = $large $idchar*
@varsym = $symbol $symchar*
@consym = \: $symchar*

@decimal     = $digit+
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


-- I'm allowing full haskell style comments here, I think that maybe
-- in the future cabal will allow this too so ... Also I don't think it
-- does significant harm at the moment
<nestcomm> {
  "{-"                                          { m (subtract 1) commentStyle }
  "-}"                                          { m (+1) commentStyle }
  $white+                                       { c defaultStyle } -- whitespace
  .                                             { c commentStyle }
}

<0> {
  "--"\-* $symbol $symchar*                     { c defaultStyle }
  "--"\-*[^\n]*                                 { c commentStyle }

 "{-"                                           { m (subtract 1) commentStyle }

 $special                                       { c defaultStyle }

 @reservedid                                    { c keywordStyle }
 @varid                                         { c defaultStyle }
 @conid                                         { c defaultStyle }

 @fieldid ":"                                   { c upperIdStyle }

 @reservedop                                    { c operatorStyle }
 @varsym                                        { c operatorStyle }
 @consym                                        { c defaultStyle  }

 @decimal 
  | 0[oO] @octal
  | 0[xX] @hexadecimal                          { c defaultStyle }

 @decimal \. @decimal @exponent?
  | @decimal @exponent                          { c defaultStyle }

 \' ($graphic # [\'\\] | " " | @escape) \'      { c stringStyle }
 \" @string* \"                                 { c stringStyle }
 .                                              { c operatorStyle }
}

{


type HlState = Int

stateToInit x | x < 0     = nestcomm
              | otherwise = 0

initState = 0

#include "alex.hsinc"
}
