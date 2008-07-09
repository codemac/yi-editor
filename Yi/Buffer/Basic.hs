{-# LANGUAGE ScopedTypeVariables, ExistentialQuantification, GeneralizedNewtypeDeriving, MultiParamTypeClasses #-}

-- Basic types useful everywhere we play with buffer.
module Yi.Buffer.Basic where
    
import Yi.Prelude
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.String
import Data.Typeable

-- | Direction of movement inside a buffer
data Direction = Backward
               | Forward
                 deriving (Eq,Ord,Typeable,Show)

reverseDir :: Direction -> Direction
reverseDir Forward = Backward
reverseDir Backward = Forward

-- | A mark in a buffer
newtype Mark = Mark {markId::Int} deriving (Eq, Ord, Show)
staticInsMark, staticSelMark :: Mark
staticInsMark = Mark (-1) -- the insertion mark
staticSelMark = Mark (-2) -- the selection mark
staticFromMark = Mark (-3) -- remember window positions in those marks
staticToMark = Mark (-4)
dummyInsMark, dummyFromMark, dummyToMark :: Mark
dummyInsMark = Mark 0
dummyFromMark = Mark 1
dummyToMark = Mark 2
    

-- | A point in a buffer
newtype Point = Point {fromPoint :: Int}           -- offset in the buffer (#bytes, NOT codepoints)
    deriving (Show, Eq, Ord, Num, Enum, Real, Integral, Bounded)

-- | Size of a buffer region
newtype Size = Size {fromSize :: Int}             -- size in bytes (#bytes, NOT codepoints)
    deriving (Show, Eq, Ord, Num, Enum, Real, Integral)

instance SemiNum Point Size where
    Point p +~ Size s = Point (p + s)
    Point p -~ Size s = Point (p - s)
    Point p ~- Point q = Size (p - q)

utf8Size :: String -> Size
utf8Size s = Size $ B.length $ UTF8.fromString s

fromUTF8ByteString :: B.ByteString -> String
fromUTF8ByteString = UTF8.toString

instance IsString LazyUTF8.ByteString where
    fromString = LazyUTF8.fromString
