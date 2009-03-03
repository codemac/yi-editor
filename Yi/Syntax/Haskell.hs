-- Copyright (c) JP Bernardy 2008

module Yi.Syntax.Haskell where

import Yi.IncrementalParse
import Yi.Lexer.Alex
import Yi.Lexer.Haskell
import Yi.Style (hintStyle, errorStyle, commentStyle, StyleName)
import Yi.Syntax.Layout
import Yi.Syntax.Tree
import Yi.Syntax.Paren (modStroke, tokenToStroke)
import Yi.Syntax
import Yi.Prelude
import Prelude ()
import Data.Monoid
import Data.Maybe
import Data.List (filter, takeWhile)

indentScanner :: Scanner (AlexState lexState) (TT)
              -> Scanner (Yi.Syntax.Layout.State Token lexState) (TT)
indentScanner = layoutHandler startsLayout [(Special '(', Special ')'),
                                            (Special '[', Special ']'),
                                            (Special '{', Special '}')] ignoredToken
                         (fmap Special ['<', '>', '.'])

-- HACK: We insert the Special '<', '>', '.', that don't occur in normal haskell
-- parsing.

ignoredToken :: TT -> Bool
ignoredToken (Tok t _ (Posn _ _ col)) = col == 0 && isComment t || t == CppDirective
    
-- isNoise :: Token -> Bool
isNoise :: (Char -> Bool) -> Token -> Bool
-- isNoise (Special _) = False
isNoise f (Special c) =  f c
isNoise _ (ReservedOp _) = False
-- isNoise _ (ReservedOp Equal) = False
isNoise _ (Reserved _) = False
isNoise _ (Comment _) = False
-- isNoise _ (Operator _) = False
isNoise _ _ = True

data Tree t
    = Paren t (Tree t) t -- A parenthesized expression (maybe with [ ] ...)
    | Block [Tree t]     -- A list of things separated by layout (as in do, where, let, etc.)
    | Atom t
    | Error t
    | Bind (Tree t) t (Tree t)
    | Expr [Tree t]
    | KW t (Tree t) -- opening kw, body
    | Cmnt [t] (Tree t) -- comments before the stuff
    | Bin (Tree t) (Tree t)
    | Empty
      deriving Show

instance Functor Tree where
  fmap = fmapDefault

instance IsTree Tree where
    subtrees (Paren _ (Expr g) _) = g
    subtrees (Block s) = s
    subtrees (Expr a) = a
    subtrees (Bind l _ r) = [l,r]
    subtrees (KW _ b) = [b]
    subtrees (Cmnt _ t) = [t]
    subtrees _ = []

instance Traversable Tree where
    traverse f t = trav1 (traverse f) f t
--    traverse f (Atom t) = Atom <$> f t
--    traverse f (Error t) = Error <$> f t
--    traverse f (Paren l g r) = Paren <$> f l <*> traverse f g <*> f r
--    traverse f (Block s) = Block <$> traverse (traverse f) s
--    traverse f (Expr a) = Expr <$> traverse (traverse f) a
--    traverse f (Bind l eq r) = Bind <$> traverse f l <*> f eq <*> traverse f r
--    traverse f (KW k h b) = KW <$> f k <*> traverse f h <*> traverse f b
--    traverse f (Cmnt cmts t) = Cmnt <$> traverse f cmts <*> traverse f t
--    traverse _ Empty = pure Empty

class XTrav t where
    trav1 :: (Applicative f) => (t a -> f (t b)) -> (a -> f b) -> t a -> f (t b)

instance XTrav Tree where
 trav1 rec f x = help x
  where
    help (Atom t) = Atom <$> f t
    help (Error t) = Error <$> f t
    help (Paren l g r) = Paren <$> f l <*> rec g <*> f r
    help (Bind l eq r) = Bind <$> rec l <*> f eq <*> rec r
    help (KW k b) = KW <$> f k <*> rec b
    help Empty = pure Empty
    help (Block s) = Block <$> traverse rec s
    help (Cmnt cmts t) = Cmnt <$> traverse f cmts <*> rec t

instance Foldable Tree where
    foldMap = foldMapDefault

-- | Search the given list, and return the 1st tree after the given
-- point on the given line.  This is the tree that will be moved if
-- something is inserted at the point.  Precondition: point is in the
-- given line.  

-- TODO: this should be optimized by just giving the point of the end
-- of the line
getIndentingSubtree :: [Tree TT] -> Point -> Int -> Maybe (Tree TT)
getIndentingSubtree roots offset line =
    listToMaybe $ [t | (t,posn) <- takeWhile ((<= line) . posnLine . snd) $ allSubTreesPosn,
                   -- it's very important that we do a linear search
                   -- here (takeWhile), so that the tree is evaluated
                   -- lazily and therefore parsing it can be lazy.
                   posnOfs posn > offset, posnLine posn == line]
    where allSubTreesPosn = [(t',posn) | root <- roots, t'@(Block (Expr (t:_):_)) <- getAllSubTrees root, 
                               let Just tok = getFirstElement t, let posn = tokPosn tok]    

-- dropWhile' f = foldMap (\x -> if f x then mempty else Endo (x :))
-- 
-- isBefore l (Atom t) = isBefore' l t
-- isBefore l (Error t) = isBefore l t
-- isBefore l (Paren l g r) = isBefore l r
-- isBefore l (Block s) = False
-- 
-- isBefore' l (Tok {tokPosn = Posn {posnLn = l'}}) = 

isEmpty :: Tree t -> Bool
isEmpty Empty = True
isEmpty _ = False

parse :: P TT (Tree TT)
parse = parse' tokT tokFromT

parse' :: (TT -> Token) -> (Token -> TT) -> P TT (Tree TT)
parse' toTok fromT = pc <* eof -- pBlockOf pDecl <* eof
    where 
      -- | parse a special symbol
      sym f = symbol (f . toTok)
      sym' d = sym (`elem` d)
      exact s = sym (== s)
      spec '|' = exact (ReservedOp Pipe)
      spec '=' = exact (ReservedOp Equal)
      spec c = sym (isSpecial [c])

      -- | Create a special character symbol
      newT c = fromT (Special c)

      pleaseSym c = (recoverWith (pure $ newT '!')) <|> spec c
      pleaseB b = (recoverWith (pure $ newT '!')) <|> b


      pFun = Bin <$> pExpr' <*> ((Block <$> some pGuard) <|> pRhs) -- add support for do
      pGuard = KW <$> spec '|' <*> (Bin <$> pExpr <*> (pRhs <|> pEmpty)) -- same here, add support for do

      pRhs, pEmpty :: P TT (Tree TT)
      pRhs = KW <$> spec '=' <*> (pExpr <|> pDo)

      pDo = KW <$> sym' [Reserved OtherLayout] <*> pExpr -- do let in and so on, should maybe match more exact char..
      pImport = KW <$> sym' [Reserved Other] <*> (pAs <|> pEmpty) -- (Atom <$> sym (`elem` [ConsIdent])) <|> pEmpty) -- catch imports, import qualified, import A as B, import A ()

      pAs = Bin <$> (Atom <$> sym' [ConsIdent]) <*> 
              (Bin <$> ((Atom <$> sym' [Reserved Other]) <|> pExpr) <*> ((Atom <$> sym' [ConsIdent]) <|> pExpr)) -- can be more sensitive

      pModule = KW <$> sym' [Reserved Module] <*> pExpr
      pType = KW <$> sym' (fmap Reserved [NewType, Data, Type]) <*> pExpr

      -- Comments
      pCommentLine = Atom <$> sym' [Comment Line]
      pComment = (pCommentLine <|> pCommentBrack)
      pCommentBrack = Paren <$> sym' [Comment Open] <*> 
                      pLine <*> (pleaseB $  sym' [Comment Close])
      pLine = Expr <$> many (Atom <$> sym' [Comment Text]) -- some comment lines
      pCommentBlock = KW <$> (sym' [Comment Open]) <*> (Block <$> (spec '<' *> (filter (not . isEmpty) <$> ((Atom <$> sym' [Comment Close]) `sepBy` spec '.')) <* spec '>'))
      -- blocks dont work yet..
      

      -- Begin the parsing
      pc = (Bin <$> (Expr <$> many (pComment <|> pCppDir)) <*> (pBlockOf pBegin <|> pEmpty)) <|> pBlockOf pBegin

      pCppDir = Atom <$> sym' [CppDirective]

      pTuple = Paren  <$>  spec '(' <*> pExpr  <*> pleaseSym ')'
      pBlockOf p = Block <$> (spec '<' *> (filter (not . isEmpty) <$> (p `sepBy` spec '.')) <* spec '>')  -- see HACK above 
      pBlock = pBlockOf pExpr
      pWhereCl = KW <$> sym' [Reserved Where] <*> ((Bin <$> (Expr <$> many pComment) <*> pd) <|> pd)

      pd = pBlockOf pDecl <|> pEmpty

      pEmpty = pure Empty

      pAny = pComment <|> pType <|> pEmpty

      pBegin = pModule <|> pDecl -- small hack to avoid allowing several module declarations

      pDecl = pImport <|> pFun <|> pExpr' <|> pEmpty <|> pType

      pExpr' = Expr <$> some pElem
      pExpr = pExpr' <|> pEmpty
      -- also, we discard the empty statements

      pElem :: P TT (Tree TT)
      pElem = pTuple
          <|> (Paren  <$>  spec '[' <*> pExpr  <*> pleaseSym ']')
          <|> (Paren  <$>  spec '{' <*> pExpr  <*> pleaseSym '}') -- records should be able to contain '='
          <|> pWhereCl
          <|> pBlock
          <|> pComment
          <|> (Atom <$> sym (isNoise (\x -> elem x ";,`")))
          <|> (Error <$> recoverWith (sym (not . isNoise (\x -> not $ elem x "})]"))))

      -- note that, by construction in Layout module, '<' and '>' will always be
      -- matched, so we don't try to recover errors with them.

(<||>) :: (t -> Bool) -> (t -> Bool) -> t -> Bool
(<||>) f g x = f x || g x


-- TODO: (optimization) make sure we take in account the begin, so we don't return useless strokes
getStrokes :: Point -> Point -> Point -> (Tree TT) -> [Stroke]
getStrokes point _begin _end t0 = result
    where getStrokes' (Atom t) = (ts t :)
          getStrokes' (Error t) = err t
          getStrokes' (Block s) = getStrokesL s
          getStrokes' (Paren l g r)
              | isErrorTok $ tokT r = err l . getStrokes' g
              -- left paren wasn't matched: paint it in red.
              -- note that testing this on the "Paren" node actually forces the parsing of the
              -- right paren, undermining online behaviour.
              | (posnOfs $ tokPosn $ l) == point || (posnOfs $ tokPosn $ r) == point - 1
               = (modStroke hintStyle (ts l) :) . getStrokes' g . (modStroke hintStyle (ts r) :)
              | otherwise  = tk l . getStrokes' g . tk r
          getStrokes' (Expr g) = getStrokesL g
          getStrokes' (Bind l eq r) = getStrokes' l . tk eq . getStrokes' r
          getStrokes' (Bin l r) = getStrokes' l . getStrokes' r
          getStrokes' (KW k b) = tk k . getStrokes' b
          getStrokes' Empty = id
          getStrokes' (Cmnt t t') = ((++) (fmap ((modStroke commentStyle) . ts) t)) . getStrokes' t'
          getStrokesL g = compose (fmap getStrokes' g)
          tk t | isErrorTok $ tokT t = id
               | otherwise = (ts t :)
          err t = (modStroke errorStyle (ts t) :)
          ts = tokenToStroke
          compose = foldr (.) id
          result = getStrokes' t0 []
          -- result = getStrokesL t0 []

