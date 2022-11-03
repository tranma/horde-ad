{-# LANGUAGE AllowAmbiguousTypes, CPP, DataKinds, FlexibleInstances, GADTs,
             QuantifiedConstraints, RankNTypes, TypeFamilies,
             UndecidableInstances #-}
{-# OPTIONS_GHC -fconstraint-solver-iterations=16 #-}
{-# OPTIONS_GHC -Wno-missing-methods #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Dual numbers and various operations on them, arithmetic and related
-- to tensors (vectors, matrices and others). This is a part of
-- the high-level API of the horde-ad library, defined using the mid-level
-- (and safely impure) API in "HordeAd.Core.DualClass". The other part
-- of the high-level API is in "HordeAd.Core.Engine".
module HordeAd.Core.DualNumber
  ( module HordeAd.Core.DualNumber
  , ADMode(..), ADModeAndNum
  , IsPrimal (..), IsPrimalAndHasFeatures, HasDelta
  , Domain0, Domain1, Domains  -- an important re-export
  ) where

import Prelude

import           Data.List.Index (imap)
import           Data.MonoTraversable (Element, MonoFunctor (omap))
import           Data.Proxy (Proxy (Proxy))
import qualified Data.Strict.Vector as Data.Vector
import qualified Data.Vector.Generic as V
import           GHC.TypeLits (KnownNat, Nat, natVal)
import           Numeric.LinearAlgebra (Numeric, Vector)
import qualified Numeric.LinearAlgebra as LA
import qualified Numeric.LinearAlgebra.Devel

import HordeAd.Core.DualClass
import HordeAd.Internal.Delta (Domain0, Domain1, Domains)

-- This is not needed in the simplified version, except for compilation
-- with the common test code.
-- | Sizes of tensor dimensions, of batches, etc., packed for passing
-- between functions as witnesses of type variable values.
data StaticNat (n :: Nat) where
  MkSN :: KnownNat n => StaticNat n

staticNatValue :: forall n i. (KnownNat n, Num i) => StaticNat n -> i
{-# INLINE staticNatValue #-}
staticNatValue = fromInteger . natVal

staticNatFromProxy :: KnownNat n => Proxy n -> StaticNat n
staticNatFromProxy Proxy = MkSN

-- * The main dual number type

-- | Values the objective functions operate on. The first type argument
-- is the automatic differentiation mode and the second is the underlying
-- basic values (scalars, vectors, matrices, tensors and any other
-- supported containers of scalars).
--
-- Here, the datatype is implemented as dual numbers (hence @D@),
-- where the primal component, the basic value, the \"number\"
-- can be any containers of scalars. The primal component has the type
-- given as the second type argument and the dual component (with the type
-- determined by the type faimly @Dual@) is defined elsewhere.
data ADVal (d :: ADMode) a = D a (Dual d a)

addParameters :: Num (Vector r)
              => Domains r -> Domains r -> Domains r
addParameters (a0, a1) (b0, b1) =
  (a0 + b0, V.zipWith (+) a1 b1)

-- Dot product and sum respective ranks and then sum it all.
dotParameters :: Numeric r => Domains r -> Domains r -> r
dotParameters (a0, a1) (b0, b1) =
  a0 LA.<.> b0
  + V.sum (V.zipWith (\v1 u1 ->
      if V.null v1 || V.null u1
      then 0
      else v1 LA.<.> u1) a1 b1)


-- * General operations, for any tensor rank

-- These instances are required by the @Real@ instance, which is required
-- by @RealFloat@, which gives @atan2@. No idea what properties
-- @Real@ requires here, so let it crash if it's really needed.
instance Eq (ADVal d a) where

instance Ord (ADVal d a) where

instance (Num a, IsPrimal d a) => Num (ADVal d a) where
  D u u' + D v v' = D (u + v) (dAdd u' v')
  D u u' - D v v' = D (u - v) (dAdd u' (dScale (-1) v'))
  D u u' * D v v' = D (u * v) (dAdd (dScale v u') (dScale u v'))
  negate (D v v') = D (negate v) (dScale (-1) v')
  abs (D v v') = D (abs v) (dScale (signum v) v')
  signum (D v _) = D (signum v) dZero
  fromInteger = constant . fromInteger

instance (Real a, IsPrimal d a) => Real (ADVal d a) where
  toRational = undefined  -- TODO?

instance (Fractional a, IsPrimal d a) => Fractional (ADVal d a) where
  D u u' / D v v' =
    let recipSq = recip (v * v)  -- ensure sharing; also elsewhere
    in D (u / v) (dAdd (dScale (v * recipSq) u') (dScale (- u * recipSq) v'))
  recip (D v v') =
    let minusRecipSq = - recip (v * v)
    in D (recip v) (dScale minusRecipSq v')
  fromRational = constant . fromRational

instance (Floating a, IsPrimal d a) => Floating (ADVal d a) where
  pi = constant pi
  exp (D u u') = let expU = exp u
                 in D expU (dScale expU u')
  log (D u u') = D (log u) (dScale (recip u) u')
  sqrt (D u u') = let sqrtU = sqrt u
                  in D sqrtU (dScale (recip (sqrtU + sqrtU)) u')
  D u u' ** D v v' = D (u ** v) (dAdd (dScale (v * (u ** (v - 1))) u')
                                      (dScale ((u ** v) * log u) v'))
  logBase x y = log y / log x
  sin (D u u') = D (sin u) (dScale (cos u) u')
  cos (D u u') = D (cos u) (dScale (- (sin u)) u')
  tan (D u u') = let cosU = cos u
                 in D (tan u) (dScale (recip (cosU * cosU)) u')
  asin (D u u') = D (asin u) (dScale (recip (sqrt (1 - u*u))) u')
  acos (D u u') = D (acos u) (dScale (- recip (sqrt (1 - u*u))) u')
  atan (D u u') = D (atan u) (dScale (recip (1 + u*u)) u')
  sinh (D u u') = D (sinh u) (dScale (cosh u) u')
  cosh (D u u') = D (cosh u) (dScale (sinh u) u')
  tanh (D u u') = let y = tanh u
                  in D y (dScale (1 - y * y) u')
  asinh (D u u') = D (asinh u) (dScale (recip (sqrt (1 + u*u))) u')
  acosh (D u u') = D (acosh u) (dScale (recip (sqrt (u*u - 1))) u')
  atanh (D u u') = D (atanh u) (dScale (recip (1 - u*u)) u')

instance (RealFrac a, IsPrimal d a) => RealFrac (ADVal d a) where
  properFraction = undefined
    -- TODO: others, but low priority, since these are extremely not continuous

instance (RealFloat a, IsPrimal d a) => RealFloat (ADVal d a) where
  atan2 (D u u') (D v v') =
    let t = 1 / (u * u + v * v)
    in D (atan2 u v) (dAdd (dScale (- u * t) v') (dScale (v * t) u'))
      -- we can be selective here and omit the other methods,
      -- most of which don't even have a differentiable codomain

constant :: IsPrimal d a => a -> ADVal d a
constant a = D a dZero

scale :: (Num a, IsPrimal d a) => a -> ADVal d a -> ADVal d a
scale a (D u u') = D (a * u) (dScale a u')

logistic :: (Floating a, IsPrimal d a) => ADVal d a -> ADVal d a
logistic (D u u') =
  let y = recip (1 + exp (- u))
  in D y (dScale (y * (1 - y)) u')

-- Optimized and more clearly written @u ** 2@.
square :: (Num a, IsPrimal d a) => ADVal d a -> ADVal d a
square (D u u') = D (u * u) (dScale (2 * u) u')

squaredDifference :: (Num a, IsPrimal d a)
                  => a -> ADVal d a -> ADVal d a
squaredDifference targ res = square $ res - constant targ

relu :: (ADModeAndNum d r, IsPrimalAndHasFeatures d a r)
     => ADVal d a -> ADVal d a
relu v@(D u _) =
  let oneIfGtZero = omap (\x -> if x > 0 then 1 else 0) u
  in scale oneIfGtZero v

reluLeaky :: (ADModeAndNum d r, IsPrimalAndHasFeatures d a r)
          => ADVal d a -> ADVal d a
reluLeaky v@(D u _) =
  let oneIfGtZero = omap (\x -> if x > 0 then 1 else 0.01) u
  in scale oneIfGtZero v


-- * Operations resulting in a scalar

sumElements0 :: ADModeAndNum d r => ADVal d (Vector r) -> ADVal d r
sumElements0 (D u u') = D (LA.sumElements u) (dSumElements0 u' (V.length u))

index0 :: ADModeAndNum d r => ADVal d (Vector r) -> Int -> ADVal d r
index0 (D u u') ix = D (u V.! ix) (dIndex0 u' ix (V.length u))

minimum0 :: ADModeAndNum d r => ADVal d (Vector r) -> ADVal d r
minimum0 (D u u') =
  D (LA.minElement u) (dIndex0 u' (LA.minIndex u) (V.length u))

maximum0 :: ADModeAndNum d r => ADVal d (Vector r) -> ADVal d r
maximum0 (D u u') =
  D (LA.maxElement u) (dIndex0 u' (LA.maxIndex u) (V.length u))

foldl'0 :: ADModeAndNum d r
        => (ADVal d r -> ADVal d r -> ADVal d r)
        -> ADVal d r -> ADVal d (Vector r)
        -> ADVal d r
foldl'0 f uu' (D v v') =
  let k = V.length v
      g !acc ix p = f (D p (dIndex0 v' ix k)) acc
  in V.ifoldl' g uu' v

altSumElements0 :: ADModeAndNum d r => ADVal d (Vector r) -> ADVal d r
altSumElements0 = foldl'0 (+) 0

-- | Dot product.
infixr 8 <.>!
(<.>!) :: ADModeAndNum d r
       => ADVal d (Vector r) -> ADVal d (Vector r) -> ADVal d r
(<.>!) (D u u') (D v v') = D (u LA.<.> v) (dAdd (dDot0 v u') (dDot0 u v'))

-- | Dot product with a constant vector.
infixr 8 <.>!!
(<.>!!) :: ADModeAndNum d r
        => ADVal d (Vector r) -> Vector r -> ADVal d r
(<.>!!) (D u u') v = D (u LA.<.> v) (dDot0 v u')

sumElementsVectorOfDual
  :: ADModeAndNum d r => Data.Vector.Vector (ADVal d r) -> ADVal d r
sumElementsVectorOfDual = V.foldl' (+) 0

softMax :: ADModeAndNum d r
        => Data.Vector.Vector (ADVal d r)
        -> Data.Vector.Vector (ADVal d r)
softMax us =
  let expUs = V.map exp us  -- used twice below, so named, to enable sharing
      sumExpUs = sumElementsVectorOfDual expUs
  in V.map (\r -> r * recip sumExpUs) expUs

-- In terms of hmatrix: @-(log res <.> targ)@.
lossCrossEntropy :: forall d r. ADModeAndNum d r
                 => Vector r
                 -> Data.Vector.Vector (ADVal d r)
                 -> ADVal d r
lossCrossEntropy targ res =
  let f :: ADVal d r -> Int -> ADVal d r -> ADVal d r
      f !acc i d = acc + scale (targ V.! i) (log d)
  in negate $ V.ifoldl' f 0 res

-- In terms of hmatrix: @-(log res <.> targ)@.
lossCrossEntropyV :: ADModeAndNum d r
                  => Vector r
                  -> ADVal d (Vector r)
                  -> ADVal d r
lossCrossEntropyV targ res = negate $ log res <.>!! targ

-- Note that this is equivalent to a composition of softMax and cross entropy
-- only when @target@ is one-hot. Otherwise, results vary wildly. In our
-- rendering of the MNIST data all labels are one-hot.
lossSoftMaxCrossEntropyV
  :: ADModeAndNum d r
  => Vector r -> ADVal d (Vector r) -> ADVal d r
lossSoftMaxCrossEntropyV target (D u u') =
  -- The following protects from underflows, overflows and exploding gradients
  -- and is required by the QuickCheck test in TestMnistCNN.
  -- See https://github.com/tensorflow/tensorflow/blob/5a566a7701381a5cf7f70fce397759483764e482/tensorflow/core/kernels/sparse_softmax_op.cc#L106
  -- and https://github.com/tensorflow/tensorflow/blob/5a566a7701381a5cf7f70fce397759483764e482/tensorflow/core/kernels/xent_op.h
  let expU = exp (u - LA.scalar (LA.maxElement u))
      sumExpU = LA.sumElements expU
      recipSum = recip sumExpU
-- not exposed: softMaxU = LA.scaleRecip sumExpU expU
      softMaxU = LA.scale recipSum expU
  in D (negate $ log softMaxU LA.<.> target)  -- TODO: avoid: log . exp
       (dDot0 (softMaxU - target) u')


-- * Operations resulting in a vector

-- @1@ means rank one, so the dual component represents a vector.
seq1 :: ADModeAndNum d r
     => Data.Vector.Vector (ADVal d r) -> ADVal d (Vector r)
seq1 v = D (V.convert $ V.map (\(D u _) -> u) v)  -- I hope this fuses
           (dSeq1 $ V.map (\(D _ u') -> u') v)

konst1 :: ADModeAndNum d r => ADVal d r -> Int -> ADVal d (Vector r)
konst1 (D u u') n = D (LA.konst u n) (dKonst1 u' n)

append1 :: ADModeAndNum d r
        => ADVal d (Vector r) -> ADVal d (Vector r)
        -> ADVal d (Vector r)
append1 (D u u') (D v v') = D (u V.++ v) (dAppend1 u' (V.length u) v')

slice1 :: ADModeAndNum d r
       => Int -> Int -> ADVal d (Vector r) -> ADVal d (Vector r)
slice1 i n (D u u') = D (V.slice i n u) (dSlice1 i n u' (V.length u))

reverse1 :: ADModeAndNum d r => ADVal d (Vector r) -> ADVal d (Vector r)
reverse1 (D u u') = D (V.reverse u) (dReverse1 u')

build1Seq :: ADModeAndNum d r
          => Int -> (Int -> ADVal d r) -> ADVal d (Vector r)
build1Seq n f = seq1 $ V.fromList $ map f [0 .. n - 1]

build1 :: ADModeAndNum d r
       => Int -> (Int -> ADVal d r) -> ADVal d (Vector r)
build1 n f =
  let g i = let D u _ = f i in u
      h i = let D _ u' = f i in u'
  in D (V.fromList $ map g [0 .. n - 1]) (dBuild1 n h)

-- The detour through a boxed vector (list probably fuses away)
-- is costly, but only matters if @f@ is cheap.
map1Seq :: ADModeAndNum d r
        => (ADVal d r -> ADVal d r) -> ADVal d (Vector r)
        -> ADVal d (Vector r)
map1Seq f (D v v') =
  let k = V.length v
      g ix p = f $ D p (dIndex0 v' ix k)
      ds = imap g $ V.toList v
  in seq1 $ V.fromList ds

map1Build :: ADModeAndNum d r
          => (ADVal d r -> ADVal d r) -> ADVal d (Vector r)
          -> ADVal d (Vector r)
map1Build f d@(D v _) = build1 (V.length v) $ \i -> f (index0 d i)

-- No padding; remaining areas ignored.
maxPool1 :: ADModeAndNum d r
         => Int -> Int -> ADVal d (Vector r) -> ADVal d (Vector r)
maxPool1 ksize stride v@(D u _) =
  let slices = [slice1 i ksize v | i <- [0, stride .. V.length u - ksize]]
  in seq1 $ V.fromList $ map maximum0 slices

softMaxV :: ADModeAndNum d r
         => ADVal d (Vector r) -> ADVal d (Vector r)
softMaxV d@(D u _) =
  let expU = exp d  -- shared in 2 places, though cse may do this for us
      sumExpU = sumElements0 expU
  in konst1 (recip sumExpU) (V.length u) * expU


-- TODO: move to separate orphan module(s) at some point
-- This requires UndecidableInstances

instance (Num (Vector r), Numeric r, Ord r)
         => Real (Vector r) where
  toRational = undefined
    -- very low priority, since these are all extremely not continuous

instance (Num (Vector r), Numeric r, Fractional r, Ord r)
         => RealFrac (Vector r) where
  properFraction = undefined
    -- very low priority, since these are all extremely not continuous

-- TODO: is there atan2 in hmatrix or can it be computed faster than this?
instance ( Floating (Vector r), Numeric r, RealFloat r )
         => RealFloat (Vector r) where
  atan2 = Numeric.LinearAlgebra.Devel.zipVectorWith atan2
    -- we can be selective here and omit the other methods,
    -- most of which don't even have a differentiable codomain

type instance Element Double = Double

type instance Element Float = Float

instance MonoFunctor Double where
  omap f = f

instance MonoFunctor Float where
  omap f = f