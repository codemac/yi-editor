{-# OPTIONS_GHC -fglasgow-exts #-}

{- |

Copyright   :  (c) The University of Glasgow 2002 
License     :  BSD-style (see http://darcs.haskell.org/packages/base/LICENSE)

Portability :  non-portable (local universal quantification)


This is a library of interactive processes combinators, usable to
define extensible keymaps. 

(This is based on Text.ParserCombinators.ReadP, originally written by Koen Claessen.)


The processes are:

* composable

* extensible: it is always possible to override a behaviour by using the <++ operator

* monadic: sequencing is done via monadic bind. (leveraging the whole
  battery of monadic tools that Haskell provides)

The processes can parse input, and write output that depends on it.
The overall idea is that processes should produce output as soon as possible; so that
an execution of a process can be interactive.

The semantics of operation is therefore quite obvious; ony disjunction deserve a bit more explanation:

@(a +++ b)@ means

* if @a@ produces output earlier than @b@, we commit to the @a@ process (the converse is true)

* if both produce output at the same time (ie. after reading the same
  character in the input), then we commit to @a@ (ie. left bias)

The extensibility is achieved by the <++ operator.

@(a <++ b)@ will commit to @a@, unless it fails before producing any output.


-}

{-

Implementation notes:
 * Being based on Text.ParserCombinators.ReadP, these processes do not hold to input (ie. no memory leak)

-}


module Yi.Interact ( 
  -- * The 'Interact' type
  Interact,      -- :: * -> *; instance Functor, Monad, MonadPlus
  
  -- * Primitive operations
  get,        -- :: Interact Char
  (+++),      -- :: Interact a -> Interact a -> Interact a
  (<++),      -- :: Interact a -> Interact a -> Interact a
  gather,     -- :: Interact a -> Interact (String, a)
  
  -- * Other operations
  write,
  pfail,      -- :: Interact a
  satisfy,    -- :: (Char -> Bool) -> Interact Char
  event,      -- :: Char -> Interact Char
  string,     -- :: String -> Interact String
  choice,     -- :: [Interact a] -> Interact a
  count,      -- :: Int -> Interact a -> Interact [a]
  between,    -- :: Interact open -> Interact close -> Interact a -> Interact a
  option,     -- :: a -> Interact a -> Interact a
  optional,   -- :: Interact a -> Interact ()
  many',
  many1',
  consumeLookahead,
  many,       -- :: Interact a -> Interact [a]
  many1,      -- :: Interact a -> Interact [a]
  skipMany,   -- :: Interact a -> Interact ()
  skipMany1,  -- :: Interact a -> Interact ()
  sepBy,      -- :: Interact a -> Interact sep -> Interact [a]
  sepBy1,     -- :: Interact a -> Interact sep -> Interact [a]
  endBy,      -- :: Interact a -> Interact sep -> Interact [a]
  endBy1,     -- :: Interact a -> Interact sep -> Interact [a]
  chainr,     -- :: Interact a -> Interact (a -> a -> a) -> a -> Interact a
  chainl,     -- :: Interact a -> Interact (a -> a -> a) -> a -> Interact a
  chainl1,    -- :: Interact a -> Interact (a -> a -> a) -> Interact a
  chainr1,    -- :: Interact a -> Interact (a -> a -> a) -> Interact a
  manyTill,   -- :: Interact a -> Interact end -> Interact [a]
  
  -- * Running a parser
  runProcessParser, -- :: Interact a -> ReadS a
  runProcess, 
  
  -- * Properties
  -- $properties
  ) 
 where

import Control.Monad( MonadPlus(..), sequence, liftM2 )

import Yi.Editor ( Action )

infixr 5 +++, <++

-- ---------------------------------------------------------------------------
-- The P type
-- is representation type -- should be kept abstract

data P event a
  = Get (event -> P event a)
  | Look Int ([event] -> P event a)
  | Fail
  | Result a (P event a)
  | Write Action (() -> P event a) -- TODO: Remove the dummy () parameter ?

-- Monad, MonadPlus

instance Monad (P event) where
  return x = Result x Fail

  (Get f)      >>= k = Get (\c -> f c >>= k)
  (Look n f)   >>= k = Look n (\s -> f s >>= k)
  Fail         >>= _ = Fail
  (Write w p)  >>= k = Write w (\u -> p u >>= k)
  (Result x p) >>= k = k x `mplus` (p >>= k)

  fail _ = Fail

instance MonadPlus (P event) where
  mzero = Fail

  -- In case of conflicting Write, we commit to the leftmost writer.
  Write w p  `mplus` _          = Write w p
  _          `mplus` Write w p  = Write w p

  -- most common case: two gets are combined
  Get f1     `mplus` Get f2     = Get (\c -> f1 c `mplus` f2 c)
  
  -- results are delivered as soon as possible
  Result x p `mplus` q          = Result x (p `mplus` q)
  p          `mplus` Result x q = Result x (p `mplus` q)

  -- fail disappears
  Fail       `mplus` p          = p
  p          `mplus` Fail       = p

  -- two looks are combined (=optimization)
  -- look + sthg else floats upwards
  Look n f   `mplus` Look m g   = Look (max n m) (\s -> f s `mplus` g s)
  Look n f   `mplus` p          = Look n (\s -> f s `mplus` p)
  p          `mplus` Look n f   = Look n (\s -> p `mplus` f s)
                                  
-- ---------------------------------------------------------------------------
-- The Interact type

newtype Interact event a = R (forall b . (a -> P event b) -> P event b)

-- Functor, Monad, MonadPlus

instance Functor (Interact event) where
  fmap h (R f) = R (\k -> f (k . h))

instance Monad (Interact event) where
  return x  = R (\k -> k x)
  fail _    = R (\_ -> Fail)
  R m >>= f = R (\k -> m (\a -> let R m' = f a in m' k))

instance MonadPlus (Interact event) where
  mzero = pfail
  mplus = (+++)

-- ---------------------------------------------------------------------------
-- Operations over P

run :: P event a -> [event] -> [(a,[event])]
run (Get f)      (c:s) = run (f c) s
run (Look _ f)   s     = run (f s) s
run (Result x p) s     = (x,s) : run p s
run (Write _ p)  s     = run (p ()) s -- drop the written things in this version.
run _            _     = []


runWrite :: P event a -> [event] -> [Action]
runWrite (Get f)      (c:s) = runWrite (f c) s
runWrite (Look _ f)   s     = runWrite (f s) s
runWrite (Result _ p) s     = runWrite p s
runWrite (Write w p)  s     = w : runWrite (p ()) s
runWrite _            _     = []


-- | Returns the amount of demanded input for running the given parser.
consumed :: P event a -> [event] -> Int
consumed (Get f)       (c:s) = 1 + consumed (f c) s
consumed (Look (-1) _) _     = error "indefinite look is not supported by consumeLookahead"
consumed (Look n f)    s     = max n (consumed (f s) s)
consumed (Result _ p)  s     = consumed p s
consumed (Write _ p)   s     = consumed (p ()) s
consumed _             _     = 0

-- ---------------------------------------------------------------------------
-- Operations over Interact

write :: Action -> Interact event ()
write w = R (Write w)

get :: Interact event event
-- ^ Consumes and returns the next character.
--   Fails if there is no input left.
get = R Get

look :: Int -> Interact event [event]
-- ^ Look-ahead: returns the part of the input that is left, without
--   consuming it. @n@ chars will be demanded.
look n = R (Look n)

pfail :: Interact event a
-- ^ Always fails.
pfail = R (\_ -> Fail)

(+++) :: Interact event a -> Interact event a -> Interact event a
-- ^ Symmetric choice.
R f1 +++ R f2 = R (\k -> f1 k `mplus` f2 k)

(<++) :: Interact event a -> Interact event a -> Interact event a


-- FIXME: this is not entirely compatible with 'consumed'.
-- We should add gets in the q part too (otherwise what's been looked 
-- at in the left operand will not be counted by 'consumed'.
R r <++ q =
  do s <- look (-1)
     probe (r return) s 0
 where
  probe (Get f)        (c:s) n = probe (f c) s (n+1)
  probe (Look _ f)     s     n = probe (f s) s n
  probe p@(Result _ _) _     n = discard n >> R (p >>=)
  probe p@(Write  _ _) _     n = discard n >> R (p >>=)
  probe _              _     n = R (Look n) >> q

discard :: Int -> Interact event ()
discard 0 = return ()
discard n  = get >> discard (n-1)

consumeLookahead :: Interact event a -> Interact event (Maybe a)
-- ^ Transforms a parser into one that does the same, except when it fails.
--   in that case, it just consumes the the amount of characters demanded by the parser to fail IF that number is > 1.
consumeLookahead (R f) = do
  s <- look (-1)
  case run (f return) s of    
    [] -> let n = consumed (f return) s in if n > 1 then discard n >> return Nothing else fail "consumeLookahead"
    _ -> R f >>= return . Just

gather :: Interact event a -> Interact event ([event], a)
-- ^ Transforms a parser into one that does the same, but
--   in addition returns the exact characters read.
gather (R m) =
  R (\k -> gath id (m (\a -> return (\s -> k (s,a)))))  
 where
  gath l (Get f)      = Get (\c -> gath (l.(c:)) (f c))
  gath _ Fail         = Fail
  gath l (Look n f)   = Look n (\s -> gath l (f s))
  gath l (Result k p) = k (l []) `mplus` gath l p
  gath l (Write w p)  = Write w (\k -> gath l (p k))

-- ---------------------------------------------------------------------------
-- Derived operations

satisfy :: (event -> Bool) -> Interact event event
-- ^ Consumes and returns the next character, if it satisfies the
--   specified predicate.
satisfy p = do c <- get; if p c then return c else pfail

event :: Eq event => event -> Interact event event
-- ^ Parses and returns the specified character.
event c = satisfy (c ==)

string :: Eq event => [event] -> Interact event [event]
-- ^ Parses and returns the specified string.
string this = do s <- look (length this); scan this s
 where
  scan []     _               = do return this
  scan (x:xs) (y:ys) | x == y = do get; scan xs ys
  scan _      _               = do pfail

choice :: [Interact event a] -> Interact event a
-- ^ Combines all parsers in the specified list.
choice []     = pfail
choice [p]    = p
choice (p:ps) = p +++ choice ps

count :: Int -> Interact event a -> Interact event [a]
-- ^ @count n p@ parses @n@ occurrences of @p@ in sequence. A list of
--   results is returned.
count n p = sequence (replicate n p)

between :: Interact event open -> Interact event close -> Interact event a -> Interact event a
-- ^ @between open close p@ parses @open@, followed by @p@ and finally
--   @close@. Only the value of @p@ is returned.
between open close p = do open
                          x <- p
                          close
                          return x

option :: a -> Interact event a -> Interact event a
-- ^ @option x p@ will either parse @p@ or return @x@ without consuming
--   any input.
option x p = p +++ return x

optional :: Interact event a -> Interact event ()
-- ^ @optional p@ optionally parses @p@ and always returns @()@.
optional p = (p >> return ()) +++ return ()


many :: Interact event a -> Interact event [a]
-- ^ Parses zero or more occurrences of the given parser.
many p = return [] +++ many1 p

many1 :: Interact event a -> Interact event [a]
-- ^ Parses one or more occurrences of the given parser.
many1 p = liftM2 (:) p (many p)

many' :: Interact event a -> Interact event [a]
-- ^ Parses zero or more occurrences of the given parser.
many' p = many1' p <++ return []

many1' :: Interact event a -> Interact event [a]
-- ^ Parses one or more occurrences of the given parser.
many1' p = liftM2 (:) p (many' p)


skipMany :: Interact event a -> Interact event ()
-- ^ Like 'many', but discards the result.
skipMany p = many p >> return ()

skipMany1 :: Interact event a -> Interact event ()
-- ^ Like 'many1', but discards the result.
skipMany1 p = p >> skipMany p

sepBy :: Interact event a -> Interact event sep -> Interact event [a]
-- ^ @sepBy p sep@ parses zero or more occurrences of @p@, separated by @sep@.
--   Returns a list of values returned by @p@.
sepBy p sep = sepBy1 p sep +++ return []

sepBy1 :: Interact event a -> Interact event sep -> Interact event [a]
-- ^ @sepBy1 p sep@ parses one or more occurrences of @p@, separated by @sep@.
--   Returns a list of values returned by @p@.
sepBy1 p sep = liftM2 (:) p (many (sep >> p))

endBy :: Interact event a -> Interact event sep -> Interact event [a]
-- ^ @endBy p sep@ parses zero or more occurrences of @p@, separated and ended
--   by @sep@.
endBy p sep = many (do x <- p ; sep ; return x)

endBy1 :: Interact event a -> Interact event sep -> Interact event [a]
-- ^ @endBy p sep@ parses one or more occurrences of @p@, separated and ended
--   by @sep@.
endBy1 p sep = many1 (do x <- p ; sep ; return x)

chainr :: Interact event a -> Interact event (a -> a -> a) -> a -> Interact event a
-- ^ @chainr p op x@ parses zero or more occurrences of @p@, separated by @op@.
--   Returns a value produced by a /right/ associative application of all
--   functions returned by @op@. If there are no occurrences of @p@, @x@ is
--   returned.
chainr p op x = chainr1 p op +++ return x

chainl :: Interact event a -> Interact event (a -> a -> a) -> a -> Interact event a
-- ^ @chainl p op x@ parses zero or more occurrences of @p@, separated by @op@.
--   Returns a value produced by a /left/ associative application of all
--   functions returned by @op@. If there are no occurrences of @p@, @x@ is
--   returned.
chainl p op x = chainl1 p op +++ return x

chainr1 :: Interact event a -> Interact event (a -> a -> a) -> Interact event a
-- ^ Like 'chainr', but parses one or more occurrences of @p@.
chainr1 p op = scan
  where scan   = p >>= rest
        rest x = do f <- op
                    y <- scan
                    return (f x y)
                 +++ return x

chainl1 :: Interact event a -> Interact event (a -> a -> a) -> Interact event a
-- ^ Like 'chainl', but parses one or more occurrences of @p@.
chainl1 p op = p >>= rest
  where rest x = do f <- op
                    y <- p
                    rest (f x y)
                 +++ return x

manyTill :: Interact event a -> Interact event end -> Interact event [a]
-- ^ @manyTill p end@ parses zero or more occurrences of @p@, until @end@
--   succeeds. Returns a list of values returned by @p@.
manyTill p end = scan
  where scan = (end >> return []) <++ (liftM2 (:) p scan)

-- ---------------------------------------------------------------------------
-- Converting between Interact event and Read

runProcessParser :: Interact event a -> [event] -> [(a,[event])]
-- ^ Converts a parser into a Haskell ReadS-style function.
runProcessParser (R f) = run (f return)



runProcess :: Interact event a -> [event] -> [Action]
-- ^ Converts a process into a function that maps input to output.
-- The process does not hold to the input stream (no space leak) and
-- produces the output as soon as possible.
runProcess (R f) = runWrite (f return)

-- ---------------------------------------------------------------------------
-- QuickCheck properties that hold for the combinators

{- $properties
The following are QuickCheck specifications of what the combinators do.
These can be seen as formal specifications of the behavior of the
combinators.

We use bags to give semantics to the combinators.

>  type Bag a = [a]

Equality on bags does not care about the order of elements.

>  (=~) :: Ord a => Bag a -> Bag a -> Bool
>  xs =~ ys = sort xs == sort ys

A special equality operator to avoid unresolved overloading
when testing the properties.

>  (=~.) :: Bag (Int,[event]) -> Bag (Int,String) -> Bool
>  (=~.) = (=~)

Here follow the properties:

>  prop_Get_Nil =
>    readP_to_S get [] =~ []
>
>  prop_Get_Cons c s =
>    readP_to_S get (c:s) =~ [(c,s)]
>
>  prop_Look s =
>    readP_to_S look s =~ [(s,s)]
>
>  prop_Fail s =
>    readP_to_S pfail s =~. []
>
>  prop_Return x s =
>    readP_to_S (return x) s =~. [(x,s)]
>
>  prop_Bind p k s =
>    readP_to_S (p >>= k) s =~.
>      [ ys''
>      | (x,s') <- readP_to_S p s
>      , ys''   <- readP_to_S (k (x::Int)) s'
>      ]
>
>  prop_Plus p q s =
>    readP_to_S (p +++ q) s =~.
>      (readP_to_S p s ++ readP_to_S q s)
>
>  prop_LeftPlus p q s =
>    readP_to_S (p <++ q) s =~.
>      (readP_to_S p s +<+ readP_to_S q s)
>   where
>    [] +<+ ys = ys
>    xs +<+ _  = xs
>
>  prop_Gather s =
>    forAll readPWithoutReadS $ \p -> 
>      readP_to_S (gather p) s =~
>	 [ ((pre,x::Int),s')
>	 | (x,s') <- readP_to_S p s
>	 , let pre = take (length s - length s') s
>	 ]
>
>  prop_String_Yes this s =
>    readP_to_S (string this) (this ++ s) =~
>      [(this,s)]
>
>  prop_String_Maybe this s =
>    readP_to_S (string this) s =~
>      [(this, drop (length this) s) | this `isPrefixOf` s]
>
>  prop_Munch p s =
>    readP_to_S (munch p) s =~
>      [(takeWhile p s, dropWhile p s)]
>
>  prop_Munch1 p s =
>    readP_to_S (munch1 p) s =~
>      [(res,s') | let (res,s') = (takeWhile p s, dropWhile p s), not (null res)]
>
>  prop_Choice ps s =
>    readP_to_S (choice ps) s =~.
>      readP_to_S (foldr (+++) pfail ps) s
>
>  prop_ReadS r s =
>    readP_to_S (readS_to_P r) s =~. r s
-}
