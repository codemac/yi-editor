{-# LANGUAGE TypeSynonymInstances, GeneralizedNewtypeDeriving #-}

module Driver where

import Data.Maybe
import System.Environment
import Control.Monad
import Test.QuickCheck hiding (promote)
import System.IO
import System.Random hiding (next)
import Text.Printf
import Data.List            (nub,sort,group,intersperse)
import qualified Data.List as L


-- Following code shamelessly stolen from XMonad.
main :: (Read t, Num t, PrintfArg t1, Num b, PrintfArg b) =>
                                    [(t1, t -> IO (Bool, b))] -> IO ()
main tests  = do
    args <- fmap (drop 1) getArgs
    let n = if null args then 100 else read (head args)
    (results, passed) <- fmap unzip $ mapM (\(s,a) -> printf "%-25s: " s >> a n) tests
    printf "Passed %d tests!\n" (sum passed)
    when (not . and $ results) $ fail "Not all tests passed!"

------------------------------------------------------------------------
--
-- QC driver
--


debug :: Bool
debug = False

mytest :: Testable a => a -> Int -> IO (Bool, Int)
mytest a n = mycheck defaultConfig
    { configMaxTest=n
    , configEvery   = \o _ -> let s = show o in s ++ [ '\b' | _ <- s ] } a
 -- , configEvery= \n args -> if debug then show n ++ ":\n" ++ unlines args else [] } a

mycheck :: Testable a => Config -> a -> IO (Bool, Int)
mycheck config a = do
    rnd <- newStdGen
    mytests config (evaluate a) rnd 0 0 []

mytests :: Config -> Gen Result -> StdGen -> Int -> Int -> [[String]] -> IO (Bool, Int)
mytests config gen rnd0 ntest nfail stamps
    | ntest == configMaxTest config = done "OK," ntest stamps >> return (True, ntest)
    | nfail == configMaxFail config = done "Arguments exhausted after" ntest stamps >> return (True, ntest)
    | otherwise               =
      do putStr (configEvery config ntest (arguments result)) >> hFlush stdout
         case ok result of
           Nothing    ->
             mytests config gen rnd1 ntest (nfail+1) stamps
           Just True  ->
             mytests config gen rnd1 (ntest+1) nfail (stamp result:stamps)
           Just False ->
             putStr ( "Falsifiable after "
                   ++ show ntest
                   ++ " tests:\n"
                   ++ unlines (arguments result)
                    ) >> hFlush stdout >> return (False, ntest)
     where
      result      = generate (configSize config ntest) rnd2 gen
      (rnd1,rnd2) = split rnd0

done :: String -> Int -> [[String]] -> IO ()
done mesg ntest stamps = putStr ( mesg ++ " " ++ show ntest ++ " tests" ++ table )
  where
    table = display
            . map entry
            . reverse
            . sort
            . map pairLength
            . group
            . sort
            . filter (not . null)
            $ stamps

    display []  = ".\n"
    display [x] = " (" ++ x ++ ").\n"
    display xs  = ".\n" ++ unlines (map (++ ".") xs)

    pairLength xss@(xs:_) = (length xss, xs)
    pairLength []         = (0, [])
    entry (n, xs)         = percentage n ntest
                       ++ " "
                       ++ concat (intersperse ", " xs)

    percentage n m        = show ((100 * n) `div` m) ++ "%"

------------------------------------------------------------------------

integralRandomR :: (Integral a, RandomGen g) => (a,a) -> g -> (a,g)
integralRandomR  (a,b) g = case randomR (fromIntegral a :: Integer,
                                         fromIntegral b :: Integer) g of
                            (x,h) -> (fromIntegral x, h)

------------------------------------------------------------------------
-- QC 2

-- from QC2
-- | NonEmpty xs: guarantees that xs is non-empty.
newtype NonEmptyList a = NonEmpty [a]
 deriving ( Eq, Ord, Show, Read )

instance Arbitrary a => Arbitrary (NonEmptyList a) where
  arbitrary   = NonEmpty `fmap` (arbitrary `suchThat` (not . null))
  coarbitrary = undefined

newtype NonEmptyNubList a = NonEmptyNubList [a]
 deriving ( Eq, Ord, Show, Read )

instance (Eq a, Arbitrary a) => Arbitrary (NonEmptyNubList a) where
  arbitrary   = NonEmptyNubList `fmap` ((fmap nub arbitrary) `suchThat` (not . null))
  coarbitrary = undefined

type Positive a = NonZero (NonNegative a)

newtype NonZero a = NonZero a
 deriving ( Eq, Ord, Num, Integral, Real, Enum, Show, Read )

instance (Num a, Ord a, Arbitrary a) => Arbitrary (NonZero a) where
  arbitrary = fmap NonZero $ arbitrary `suchThat` (/= 0)
  coarbitrary = undefined

newtype NonNegative a = NonNegative a
 deriving ( Eq, Ord, Num, Integral, Real, Enum, Show, Read )

instance (Num a, Ord a, Arbitrary a) => Arbitrary (NonNegative a) where
  arbitrary =
    frequency
      [ (5, (NonNegative . abs) `fmap` arbitrary)
      , (1, return 0)
      ]
  coarbitrary = undefined

-- | Generates a value that satisfies a predicate.
suchThat :: Gen a -> (a -> Bool) -> Gen a
gen `suchThat` p =
  do mx <- gen `suchThatMaybe` p
     case mx of
       Just x  -> return x
       Nothing -> sized (\n -> resize (n+1) (gen `suchThat` p))

-- | Tries to generate a value that satisfies a predicate.
suchThatMaybe :: Gen a -> (a -> Bool) -> Gen (Maybe a)
gen `suchThatMaybe` p = sized (try 0 . max 1)
 where
  try _ 0 = return Nothing
  try k n = do x <- resize (2*k+n) gen
               if p x then return (Just x) else try (k+1) (n-1)
