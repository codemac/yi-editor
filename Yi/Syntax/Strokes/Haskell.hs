module Yi.Syntax.Strokes.Haskell (getStrokes) where

import Prelude ()
import Data.Maybe
import Data.List (delete, filter, union, takeWhile, (\\))
import Yi.IncrementalParse
import Yi.Lexer.Alex
import Yi.Lexer.Haskell
import Yi.Style
import Yi.Syntax.Layout
import Yi.Syntax.Tree
import qualified Yi.Syntax.BList as BL
import Yi.Syntax
import Yi.Prelude
import Prelude ()
import Data.Monoid
import Data.DeriveTH
import Data.Derive.Foldable
import Data.Derive.Data
import Data.Maybe
import Data.Data
import Data.Typeable
import Data.Generics.Schemes
import Yi.Syntax.Haskell

isError' :: Exp TT ->[Exp TT]
isError' n = (listify isE' n)
    where isE' (PError _ _) = True
          isE' _ = False

-- TODO: (optimization) make sure we take in account the begin, so we don't return useless strokes
getStrokes :: Point -> Point -> Point -> Tree TT -> [Stroke]
getStrokes point begin _end t0 = trace (show t0) result
    where result = appEndo (getStrokeProg point begin _end t0) []

-- | getStroke Program
getStrokeProg ::  Point -> Point -> Point -> Tree TT -> Endo [Stroke]
getStrokeProg point begin _end prog
    = case prog of
        (Program c m)
            ->com c <> funPr m
        (ProgMod m body)
            -> getStrokeMod point begin _end m
            <> getStrokeProg point begin _end body
        (Body imps exps exps') 
            -> funImp imps
            <> getStr tkDConst point begin _end exps
            <> getStr tkDConst point begin _end exps'
  where funPr (Just pr)    = getStrokeProg point begin _end pr
        funPr Nothing      = foldMap id []
        funImp imps        = foldMap (getStrokeImp point begin _end) imps

-- | Get strokes Module for module
getStrokeMod :: Point -> Point -> Point -> PModule TT -> Endo [Stroke]
getStrokeMod point begin _end (PModule m na e w)
              | isErrN na || isErrN w
                     = paintAtom errorStyle m
                    <> getStr tkImport point begin _end na <> getStrokes' e
                    <> getStrokes' w
              | otherwise = getStrokes' m <> getStr tkImport point begin _end na
                         <> getStrokes' e <> getStrokes' w
    where getStrokes' r = getStr tkDConst point begin _end r

-- | Get strokes for Imports
getStrokeImp ::  Point -> Point -> Point -> PImport TT -> Endo [Stroke]
getStrokeImp point begin _end (PImport m qu na t t')
              | isErrN t' || isErrN na || isErrN t
                          = paintAtom errorStyle m <> paintQu qu
                         <> getStr tkImport point begin _end na <> paintAs t  <> paintHi t'
              | otherwise = getStrokes' m <> paintQu qu
                         <> getStr tkImport point begin _end na <> paintAs t  <> paintHi t'
    where getStrokes' r = getStr tkDConst point begin _end r
          paintAs (Opt (Just (KW (PAtom n c) tw)))
              = (one $ (fmap (const keywordStyle) . tokToSpan) n) <> com c
             <> getStr tkImport point begin _end tw
          paintAs a = getStrokes' a
          paintQu (Opt (Just ((PAtom n c)))) = (one $ (fmap (const keywordStyle) . tokToSpan) n) <> com c
          paintQu a = getStrokes' a
          paintHi (Bin (KW (PAtom n c) tw) r) = (one $ (fmap (const keywordStyle) . tokToSpan) n)
                                             <> com c <> getStr tkImport point begin _end tw
                                             <> getStrokes' r
          paintHi a = getStrokes' a

-- | Get strokes for expressions and declarations
getStr ::(TT -> Endo [Stroke]) -> Point -> Point -> Point -> Exp TT -> Endo [Stroke]
getStr tk point begin _end t0 = getStrokes' t0
    where getStrokes' ::Exp TT -> Endo [Stroke]
          getStrokes' (PAtom t c) = tk t <> com c
          getStrokes' (TS col ts') = tk col <> foldMap (getStr tkTConst point begin _end) ts'
          getStrokes' (Modid t c) = tkImport t <> com c
          getStrokes' (Paren (PAtom l c) g (PAtom r c'))
              | isErr r = errStyle l <> getStrokes' g
              -- left paren wasn't matched: paint it in red.
              -- note that testing this on the "Paren" node actually forces the parsing of the
              -- right paren, undermining online behaviour.
              | (posnOfs $ tokPosn $ l) ==
                    point || (posnOfs $ tokPosn $ r) == point - 1
               = pStyle hintStyle l <> com c <> getStrokes' g
                      <> pStyle hintStyle r <> com c'
              | otherwise  = tk l <> com c <> getStrokes' g
                                  <> tk r <> com c'
          getStrokes' (Paren (PAtom l c) g e@(PError _ _))
              = errStyle l <> com c <> getStrokes' g <> getStrokes' e
          getStrokes' (PError t c) = errStyle t <> com c
          getStrokes' (Block s) = BL.foldMapAfter begin getStrokesL s
          getStrokes' (PFun f args s c rhs)
              | isErrN args || isErr s
              = foldMap errStyle f <> getStrokes' args
              | otherwise = getStrokes' f <> getStrokes' args
                          <> tk s <> com c <> getStrokes' rhs
          getStrokes' (Expr g) = getStrokesL g
          getStrokes' (PWhere c c' exp) = tk c <> com c' <> getStrokes' exp
          getStrokes' (RHS eq g) = getStrokes' eq <> getStrokesL g
--           getStrokes' (RHS eq g) = paintAtom errorStyle eq <> foldMap errStyle (Expr g) -- will color rhs functions red
          getStrokes' (Bin l r) = getStrokes' l <> getStrokes' r
          getStrokes' (KW l r') = getStrokes' l <> getStrokes' r'
          getStrokes' (Op op c r') = tk op <> com c <> getStrokes' r'
          getStrokes' (PType m c na exp eq c' b)
              | isErrN b ||isErrN na || isErr eq
                          = errStyle m <> com c  <> getStrokes' na
                                       <> getStrokes' exp <> tk eq
                                       <> com c <> getStrokes' b
              | otherwise = tk m <> com c <> getStrokes' na
                                       <> getStrokes' exp <> tk eq
                                       <> com c' <> getStrokes' b
          getStrokes' (PData m c na exp eq)
              | isErrN exp || isErrN na ||isErrN eq
                           = errStyle m <> com c <> getStrokes' na
                                        <> getStrokes' eq
              | otherwise = tk m <> com c <> getStrokes' na
                         <> getStrokes' exp <> getStrokes' eq
          getStrokes' (PData' eq c' b d) =
                tk eq <> com c' <> getStrokes' b
                            <> getStrokes' d
          getStrokes' (PLet l c expr i) =
                tk l <> com c <> getStrokes' expr <> getStrokes' i
          getStrokes' (PIn t l) = tk t <> getStrokesL l
          getStrokes' (Opt (Just l)) =  getStrokes' l
          getStrokes' (Opt Nothing) = getStrokesL []
          getStrokes' (Context fAll l arr c) =
                getStrokes' fAll <> getStrokes' l <> tk arr <> com c
          getStrokes' (TC l) = getStr tkTConst point begin _end l
          getStrokes' (DC (PAtom l c)) = tkDConst l <> com c
          getStrokes' (DC r) = getStrokes' r -- do not color operator dc
          getStrokes' (PGuard ls) = getStrokesL ls
          getStrokes' (PGuard' t e t' e')
              | isErrN e ||isErrN e' ||isErr t'
              = errStyle t <> getStrokes' e <> tk t' <> getStrokes' e'
              | otherwise
              = one (ts t) <> getStrokes' e <> tk t' <> getStrokes' e'
          getStrokes' (SParen (PAtom l c) (SParen' g (PAtom r c') e))
              | isErr r = errStyle l <> getStrokes' g <> getStrokes' e
              -- left paren wasn't matched: paint it in red.
              -- note that testing this on the "Paren" node actually forces the parsing of the
              -- right paren, undermining online behaviour.
              | (posnOfs $ tokPosn $ l) ==
                    point || (posnOfs $ tokPosn $ r) == point - 1
               = pStyle hintStyle l <> com c <> getStrokes' g
                      <> pStyle hintStyle r <> com c' <> getStrokes' e
              | otherwise  = tk l <> com c <> getStrokes' g
                                  <> tk r <> com c' <> getStrokes' e
          getStrokes' (PClass e e' exp exp' e'')
              | isErrN e' || isErrN exp || isErrN exp' || isErrN e''
              = paintAtom errorStyle e <> getStrokes' e'
                <> getStrokes' exp <> getStrokes' exp'
                <> getStrokes' e''
              | otherwise = getStrokes' e <> getStrokes' e'
                <> getStrokes' exp <> getStrokes' exp'
                <> getStrokes' e''
          getStrokes' (PInstance e e' exp exp' e'')
              | isErrN e' || isErrN exp || isErrN exp' || isErrN e''
              = paintAtom errorStyle e <> getStrokes' e'
                <> getStrokes' exp <> getStrokes' exp'
                <> getStrokes' e''
              | otherwise = getStrokes' e <> getStrokes' e'
                <> getStrokes' exp <> getStrokes' exp'
                <> getStrokes' e''
          getStrokes' a = error (show a)
          getStrokesL = foldMap getStrokes'

-- Stroke helpers follows

tokenToAnnot :: TT -> Maybe (Span String)
tokenToAnnot = sequenceA . tokToSpan . fmap tokenToText

ts :: TT -> Stroke
ts = tokenToStroke

pStyle :: StyleName -> TT -> Endo [Stroke]
pStyle style = one . (modStroke style) . ts

one :: Stroke -> Endo [Stroke]
one x = Endo (x :)

paintAtom :: StyleName -> (Exp TT) -> Endo [Stroke]
paintAtom col (PAtom a c) = pStyle col a <> com c
paintAtom _ _ = error "wrong usage of paintAtom"

isErr :: TT -> Bool
isErr = isErrorTok . tokT

isErrN :: (Exp TT) -> Bool
isErrN t = (any isErr t) 
        || (not $ null $ isError' t)

errStyle :: TT -> Endo [Stroke]
errStyle = pStyle errorStyle

tokenToStroke :: TT -> Stroke
tokenToStroke = fmap tokenToStyle . tokToSpan

modStroke :: StyleName -> Stroke -> Stroke
modStroke f = fmap (f `mappend`)

com :: [TT] -> Endo [Stroke]
com r = foldMap tkDConst r

tk' :: (TT -> Bool) -> (TT -> Endo [Stroke]) -> TT -> Endo [Stroke]
tk' f s t | isErr t = errStyle t
          | elem (tokT t) (fmap Reserved [As, Qualified, Hiding]) 
            = one $ (fmap (const variableStyle) . tokToSpan) t
          | f t = s t
          | otherwise = one (ts t)

tkTConst :: TT -> Endo [Stroke]
tkTConst = tk' (const False) (const (Endo id))


tkDConst :: TT -> Endo [Stroke]
tkDConst = tk' ((== ConsIdent) . tokT) (pStyle dataConstructorStyle)

tkImport :: TT -> Endo [Stroke]
tkImport = tk' ((== ConsIdent) . tokT) (pStyle importStyle)