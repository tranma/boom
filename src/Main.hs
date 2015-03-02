
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}

-- trust me it's fine
{-# LANGUAGE UndecidableInstances #-}

import Control.Applicative
import Control.Lens
import Data.Text (Text)
import System.Random.MWC
import Control.Monad.State
import Control.Monad.Primitive
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Statistics.Distribution
import Statistics.Distribution.Normal


type Coord = (Dim, Dim)
type ID    = Text
type Speed = Double

newtype Dim = Dim Double
  deriving (Show, Eq, Ord, Fractional)

modDim s
  = let f = floor $ abs s / limit
    in  Dim $ signum s * (abs s - fromIntegral f * limit)
  where limit = 600

instance Num Dim where
  (+) (Dim x) (Dim y) = modDim (x + y)
  (-) (Dim x) (Dim y) = modDim (x - y)
  (*) (Dim x) (Dim y) = modDim (x * y)
  abs (Dim x)         = Dim (abs x)
  signum (Dim x)      = Dim (signum x)
  fromInteger i       = modDim (fromInteger i :: Double)

data Direction = N | NE | E | SE | S | SW | W | NW
     deriving (Show, Eq, Enum, Bounded)

type Wind = (Direction, Speed)

data Balloon = Balloon
  { _coord     :: Coord
  , _temp      :: Double
  } deriving (Show)

makeLenses ''Balloon

data Observation = Observation
  { _obT :: POSIXTime
  , _obC :: Coord
  , _obV :: Double
  } deriving (Show)

makeLenses ''Observation

data Post = Post
  { _location    :: Coord
  , _observation :: Maybe Observation
  } deriving (Show)

makeLenses ''Post

data World = World
  { _balloon :: Balloon
  , _posts   :: [Post]
  , _now     :: POSIXTime
  , _wind    :: Wind
  } deriving (Show)

makeLenses ''World

type WorldS = (Gen (PrimState IO), World)
type WorldM = StateT WorldS IO

windDirection :: Lens' World Direction
windDirection = wind . _1

windSpeed     :: Lens' World Speed
windSpeed     = wind . _2

minDirection  = fromEnum (minBound :: Direction)
maxDirection  = fromEnum (maxBound :: Direction)

-- | Things that vary by a little bit, affected by something.
--
class Vary x where
  type Variant v
  vary :: (Functor m, PrimMonad m) => Gen (PrimState m) -> Variant x -> x -> m x

instance Vary Balloon where
  type Variant Balloon = Wind
  vary gen (direction, speed) balloon = do
    -- temperature
    let t  = balloon ^. temp
        tD = normalDistr t 1.0 -- temperature varies by some SD
    t'    <- genContVar tD gen

    return $ balloon & (coord    %~ move (direction, speed))
                     . (temp     .~ t')

instance Vary World where
  type Variant World = ()

  vary gen _ world = do
    -- advance time
    let t  = world ^. now
        tD = normalDistr (fromIntegral ((round t + 2) :: Int)) 2.0 -- time varies by SD 1s, skewed towards progress
    tv    <- genContVar tD gen
    let t' = fromRational $ toRational tv

    -- wind direction
    let dir   = world ^. windDirection
        dirD  = normalDistr (fromIntegral $ fromEnum dir) 1.0
    dir'     <- toEnum
            <$> bound (minDirection, maxDirection)
            <$> floor
            <$> genContVar dirD gen

    -- wind speed
    let v  = world ^. windSpeed
        vD = normalDistr v 5.0
    v'    <- abs <$> genContVar vD gen

    -- blows the balloon
    b     <- vary gen (dir',v') (world ^. balloon)

    -- send observations!
    let ps = send t' b (world ^. posts)

    return $ world & (now           .~ t')
                   . (windDirection .~ dir')
                   . (windSpeed     .~ v')
                   . (balloon       .~ b)
                   . (posts         .~ ps)

-- | This might give more biases to the edge values.
--
bound :: (Ord a) => (a,a) -> a -> a
bound (x1,x2) y
  | y < x1    = x1
  | y > x2    = x2
  | otherwise = y

send :: POSIXTime -> Balloon -> [Post] -> [Post]
send t b = map f
  where f p | (p ^. location) `inRange` (b ^. coord)
            = let ob = Observation t (b ^. coord) (b ^. temp)
              in          p & observation .~ Just ob
            | otherwise = p & observation .~ Nothing

inRange :: Coord -> Coord -> Bool
inRange (a,b) (x,y) = abs (a - x) < d && abs (b - y) < d
  where d = 100

move :: Wind -> Coord -> Coord
move (d, Dim -> s) (x,y) = case d of
  N  -> (x      , y + s)
  NE -> (x + s/2, y + s/2)
  E  -> (x + s  , y)
  SE -> (x + s/2, y - s/2)
  S  -> (x      , y - s)
  SW -> (x - s/2, y - s/2)
  W  -> (x - s  , y)
  NW -> (x - s/2, y + s/2)

defaultWorld :: World
defaultWorld = World
  (Balloon (0,0) 10)
  [ Post (5,7) Nothing
  , Post (50,80) Nothing
  , Post (360, 120) Nothing ]
  100
  (S,0)

initWorld :: Gen RealWorld -> IO WorldS
initWorld gen = do
  world <- vary gen () defaultWorld
  return (gen, world)

main = withSystemRandom initGo
  where go :: Gen (PrimState IO) -> World -> Int -> IO ()
        go g w n | n > 0 = do w' <- vary g () w
                              print w'
                              go g w' (n-1)
                 | otherwise = print "done"
        initGo :: Gen (PrimState IO) -> IO ()
        initGo g = do
          (_,w) <- initWorld g
          print "initial"
          print w
          go g w 30
