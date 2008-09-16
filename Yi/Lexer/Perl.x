-- -*- haskell -*- 
-- Simple lexer for Perl source files.
-- This started as a copy of the C++ lexer so some bits and pieces don't make sense for Perl.

{
{-# OPTIONS -w  #-}
module Yi.Lexer.Perl ( initState, alexScanToken ) where
{- Standard Library Modules Imported -}
import Yi.Lexer.Alex
{- External Library Modules Imported -}
{- Local Modules Imported -}
import qualified Yi.Syntax
import Yi.Style
{- End of Module Imports -}

}

$whitechar = [\ \t\n\r\f\v]
$special   = [\(\)\,\;\[\]\{\}]

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
$idchar    = [$alpha $ascdigit]
$nl        = [\n\r]

@reservedId = 
    if
    | while
    | do
    | then
    | last
    | next
    | redo
    | continue
    | goto
    | redo
    | for
    | foreach
    | unless
    | until
    | elsif
    | else
    | sub
    | package
    | use
    | require
    | our
    | my
    | defined
    | undef
    | exists
    | die
    | shift

@seperator = $whitechar+ | $special
@interpVarSeperator = [^$idchar] | $nl

@reservedop = 
  "->" | "*" | "+" | "-" | "%" | \\ | "||" | "&&" | "?" | ":" | "=>" 
  | "or" | "xor" | "and" | "ne" | "eq"
  | "=~" | "!~"

@preMatchRegexOp = @reservedop | "(" | "{" | ","

-- Standard variables
-- TODO: Handle casts of the form @varTypeOp{@varid}
@varTypeOp =
    "@"
    | "$"
    | "%"

@varPackageSpec = $idchar+ "::" 
@varIdentifier  = @varPackageSpec* $idchar+

-- TODO: A lot! There is a whole list of special global variables.
@specialVarIdentifier = 
    "_" | ARG
    | "." | INPUT_LINE_NUMBER | NR
    | "?" | CHILD_ERROR
    | ENV

-- TODO: The specialVarToken should have an entry like the following:
-- | "/" | INPUT_RECORD_SEPARATOR | RS
-- but that messes up the hacked together regex support.

-- Standard classes
@decimal     = $digit+
@octal       = $octit+
@hexadecimal = $hexit+
@exponent    = [eE] [\-\+] @decimal

-- string components
$cntrl   = [$large \@\[\\\]\^\_]
@ascii   = \^ $cntrl | NUL | SOH | STX | ETX | EOT | ENQ | ACK
         | BEL | BS | HT | LF | VT | FF | CR | SO | SI | DLE
         | DC1 | DC2 | DC3 | DC4 | NAK | SYN | ETB | CAN | EM
         | SUB | ESC | FS | GS | RS | US | SP | DEL

-- The charesc set contains more than it really should.
-- It currently tries to be the superset of all characters that are possible 
-- to escape in the various quoting modes. Problem is, the actual set of 
-- Characters that should be escapable in any quoting mode depends on the 
-- delimiter of the quoting mode and I haven't implemented such fanciness
-- yet.
$charesc = [abfnrtv\\\"\'\&\`\/]
@escape  = \\ ($charesc | @ascii | @decimal | o @octal | x @hexadecimal)
@gap     = \\ $whitechar+ \\

@nonInterpolatingString  = $graphic # [\'] | " " 

@quoteLikeDelimiter = $special | $ascsymbol | \" | \'

-- Heredoc
@heredocId = $idchar+

-- Perldoc
-- perldoc starts at a "line that begins with an equal sign and a word"
-- (man perlsyn)
@perlDocStartWord = "=" [^$whitechar]+

perlHighlighterRules :-

<0> 
{
    -- Conditionalize on not being prefixed with a character that could 
    -- indicate a regex-style quote.
    [^smqrty]^"#"[^\n]*                            { c commentStyle }
    ^"#"[^\n]*                                     { c commentStyle }

    @seperator @reservedId / @seperator            { c keywordStyle }
    ^ @reservedId / @seperator                     { c keywordStyle }

    @varTypeOp
        { m (\s -> HlInVariable 0 s) (const $ withFg darkcyan) }

    @reservedop                                    { c operatorStyle }

    @decimal 
    | 0[oO] @octal
    | 0[xX] @hexadecimal                           { c numberStyle }

    @decimal \. @decimal @exponent?
    | @decimal @exponent                           { c numberStyle }

    -- Chunks that are handled as interpolating strings.
    \"
    { 
        m (\_ -> HlInInterpString False "\"" ) operatorStyle 
    }
    "`" 
    {
        m (\_ -> HlInInterpString False "`" ) operatorStyle
    }

    -- Matching regex quote-like operators are also kinda like interpolating strings.
    -- In order to prevent a / delimited regex quote from being confused with 
    -- division this only matches in the case the / is preeceded with the usual 
    -- context I use it.
    ^($white*)"/"
        { m (\_ -> HlInInterpString True "/" ) operatorStyle }
    (@preMatchRegexOp $whitechar* "/")
        {
            m (\_ -> HlInInterpString True "/" ) operatorStyle
        }
    -- "?"
    --     {
    --         m (\_ -> HlInInterpString True "?" ) operatorStyle
    --     }

    "m/"
        {
            \str _ -> (HlInInterpString True "/", operatorStyle)
        }

    "s/"
        {
            \str _ -> (HlInSubstRegex "/", operatorStyle)
        }

    "m#"
        {
            \str _ -> (HlInInterpString True "#", operatorStyle)
        }

    "s#"
        {
            \str _ -> (HlInSubstRegex "#", operatorStyle)
        }

    -- Heredocs are kinda like interpolating strings...
    "<<" @heredocId
    { 
        \str _ -> (HlInHeredoc (drop 2 $ fmap snd str), operatorStyle)
    }

    -- Chunks that are handles as non-interpolating strings.
    \' 
    { 
        m (\_ -> HlInString '\'') operatorStyle 
    }

    "qw" @quoteLikeDelimiter
    {
        \str _ -> 
            let startChar = head $ drop 2 $ fmap snd str
                closeChar '(' = ')'
                closeChar '{' = '}'
                closeChar '<' = '>'
                closeChar '[' = ']'
                closeChar c   = c
            in (HlInString (closeChar startChar), operatorStyle)
    }

    -- perldoc starts at a "line that begins with an equal sign and a word"
    -- (man perlsyn)
    ^ @perlDocStartWord
        {
            m (\_ -> HlInPerldoc) commentStyle
        }


    -- Everything else is unstyled.
    $white                                         { c defaultStyle }
    .                                              { c defaultStyle }
}

<interpString>
{
    @escape { c defaultStyle }
    $white+ { c defaultStyle }

    -- Prevent $ at the end of a regex quote from being recognized as a 
    -- variable.
    "$"/
        {
            \state _ _ postInput ->
                case state of
                    HlInInterpString True end_tag ->
                        let postText = take (length end_tag) $ alexCollectChar postInput
                        in if (postText == end_tag) then True else False
                    HlInSubstRegex end_tag ->
                        let postText = take (length end_tag) $ alexCollectChar postInput
                        in if (postText == end_tag) then True else False
                    _ -> False
        }
        {
            c stringStyle
        }

    @varTypeOp
        { m (\s -> HlInVariable 0 s) (const $ withFg darkcyan) }

    ./
        {
            \state preInput _ _ ->
                case state of
                    HlInInterpString _ end_tag ->
                        let inputText = take (length end_tag) $ alexCollectChar preInput
                        in if (inputText == end_tag) then True else False
                    HlInSubstRegex end_tag ->
                        let inputText = take (length end_tag) $ alexCollectChar preInput
                        in if (inputText == end_tag) then True else False
                    _ -> False
        }
        {
            m fromQuoteState operatorStyle
        }
    .   { c stringStyle }
}

<heredoc>
{
    ^(@heredocId\n)/
        {
            \state preInput _ _ ->
                case state of
                    HlInHeredoc tag ->
                        let inputText = take (length tag) $ alexCollectChar preInput
                        in if (inputText == tag) then True else False
                    _ -> False
        }
        {
            m fromQuoteState operatorStyle
        }
    $white+ { c defaultStyle }
    @varTypeOp
        { m (\s -> HlInVariable 0 s) (const $ withFg darkcyan) }
    .   { c stringStyle }
}

<variable>
{
    -- Support highlighting uses of the # to determine subscript of the last element.
    -- This isn't entirely correct as it'll accept $########foo.
    (@varTypeOp | "#")
        { c $ const (withFg darkcyan) }
    "{"
        { m increaseVarCastDepth $ const (withFg darkcyan) }
    "}"
        { m decreaseVarCastDepth $ const (withFg darkcyan) }
    @specialVarIdentifier
        { m exitVarIfZeroDepth $ const (withFg cyan) }
    @varIdentifier
        { m exitVarIfZeroDepth $ const (withFg darkcyan) }
    $white 
        { m (\(HlInVariable _ s) -> s) defaultStyle }
    .
        { m (\(HlInVariable _ s) -> s) defaultStyle }
}

<perldoc>
{
    ^ "=cut"
        { 
            m fromQuoteState commentStyle 
        }
    $white+ { c defaultStyle }
    . { c commentStyle }
}

<string>
{
    $white+ { c defaultStyle }
    ./
        {
            \state preInput _ _ ->
                case state of
                    HlInString endDelimiter ->
                        let currentChar = head $ alexCollectChar preInput
                        in if (currentChar == endDelimiter) then True else False
                    _ -> False
        }
        {
            m fromQuoteState operatorStyle
        }
    .   { c stringStyle }
}

{

data HlState = 
    HlInCode
    -- Boolean indicating if the interpolated quote is a regex and deliminator of quote.
    | HlInInterpString Bool String
    | HlInString Char
    | HlInHeredoc String
    | HlInPerldoc
    | HlInSubstRegex String
    -- Count of nested {} and the state to transition to once variable is done.
    | HlInVariable Int HlState

fromQuoteState (HlInSubstRegex s) = HlInInterpString True s
fromQuoteState _ = HlInCode

increaseVarCastDepth (HlInVariable n s) = HlInVariable (n + 1) s
increaseVarCastDepth state = error "increaseVarCastDepth applied to non HlInVariable state"

decreaseVarCastDepth (HlInVariable n s) | n <= 1    = s
                                        | otherwise = HlInVariable (n - 1) s
decreaseVarCastDepth state = error "decreaseVarCastDepth applied to non HlInVariable state"

exitVarIfZeroDepth (HlInVariable 0 s) = s
exitVarIfZeroDepth s = s

type Token = StyleName

stateToInit HlInCode = 0
stateToInit (HlInInterpString _ _) = interpString
stateToInit (HlInString _) = string
stateToInit (HlInHeredoc _) = heredoc
stateToInit HlInPerldoc = perldoc
stateToInit (HlInSubstRegex _) = interpString
stateToInit (HlInVariable _ _) = variable

initState :: HlState
initState = HlInCode

#include "alex.hsinc"
}
