{-# LANGUAGE DataKinds, TypeFamilies #-}
module TestConditionalSynth (testTrees) where

import Prelude

import           Data.List (nub, sort, unfoldr)
import qualified Data.Strict.Vector as Data.Vector
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Storable
import           Foreign.Storable (Storable)
import           Foreign.Storable.Tuple ()
import           GHC.Exts (inline)
import           Numeric.LinearAlgebra (Vector)
import qualified Numeric.LinearAlgebra as HM
import           System.Random
import           Test.Tasty
import           Test.Tasty.HUnit hiding (assert)

import HordeAd
import HordeAd.Tool.MnistFcnnVector
import TestCommonEqEpsilon

testTrees :: [TestTree]
testTrees = [ conditionalSynthTests
            ]


-- * A neural net that learns to represent a list of input and result pairs
-- as a function that is a sum of conditionals with linear conditions
-- and linear or zero results.
--
-- The samples are easy: inputs and results are integers and inputs
-- are sorted and not repeating (with input repetition it would not be
-- a function or the output would need to be repeated as well).

bloat :: Int
bloat = 1

lenSynthV :: Int -> Int -> Data.Vector.Vector Int
lenSynthV width nSamples =
  V.fromList $ replicate width (nSamples * 2) ++ [width]
               ++ replicate (bloat * nSamples * 3) width
               ++ replicate 3 (bloat * nSamples)

-- If ai ranges over ps1, bi over ps2 and ci over ps4,
-- the value of the function on input x is
-- the sum of if x * ai + bi > 0 then (x * ai + bi) * ci else 0, which is
-- the sum of if x * ai + bi > 0 then x * ai * ci + bi * ci else 0
-- so each condition depends in a linear way on x and each result,
-- if not 0, depends in a linear way on input x.
--
-- To approximate the samples (a list of input and result pairs on which
-- parameters are trained or tested) using this code, divide the input
-- and multiply result appropriately, see @synthLossSquared@.
synthValue :: forall d r. IsScalar d r
           => (DualNumber d (Vector r) -> DualNumber d (Vector r))
           -> r
           -> DualNumber d (Vector r)
           -> DualNumber d (Vector r)
           -> DualNumber d (Vector r)
           -> DualNumber d r
synthValue factivation x ps1@(D u _) ps2 ps3 =
  let activated = factivation $ scale (HM.konst x (V.length u)) ps1 + ps2
  in activated <.>! ps3

synthLossSquared :: IsScalar d r
                 => (DualNumber d (Vector r) -> DualNumber d (Vector r))
                 -> r
                 -> DualNumber d (Vector r)
                 -> DualNumber d (Vector r)
                 -> DualNumber d (Vector r)
                 -> r
                 -> DualNumber d r
synthLossSquared factivation x ps1 ps2 ps3 targ =
  let y = inline synthValue factivation (x / 1000) ps1 ps2 ps3
  in squaredDifference (targ / 10000) y  -- smaller target to overcome @tanh@ clamping

-- Inlined to avoid the tiny overhead of calling an unknown function.
sumResultsDual :: forall d r a. (IsScalar d r, Storable a)
               => (a -> DualNumber d r)
               -> Vector a
               -> DualNumber d r
{-# INLINE sumResultsDual #-}
sumResultsDual f as =
  let g :: DualNumber d r -> a -> DualNumber d r
      g !acc a = acc + f a
      sumUs = V.foldl' g 0 as
  in sumUs

synthLossAll
  :: forall d r. IsScalar d r
  => (DualNumber d (Vector r) -> DualNumber d (Vector r))
  -> Data.Vector.Storable.Vector (r, r)
  -> DualNumber d (Vector r)
  -> DualNumber d (Vector r)
  -> DualNumber d (Vector r)
  -> DualNumber d r
synthLossAll factivation samples ps1 ps2 ps3 =
  let f :: (r, r) -> DualNumber d r
      f (x, y) = inline synthLossSquared factivation x ps1 ps2 ps3 y
  in sumResultsDual f samples

sumTrainableInputsS :: forall d r. IsScalar d r
                    => DualNumber d (Vector r)
                    -> Int
                    -> DualNumberInputs d r
                    -> Int
                    -> Data.Vector.Vector (DualNumber d r)
sumTrainableInputsS x offset inputs width =
  let f :: Int -> DualNumber d r
      f i = sumTrainableInputsV x (offset + i) inputs
  in V.generate width f

splitLayerV :: forall d r. IsScalar d r
            => (DualNumber d (Vector r) -> DualNumber d (Vector r))
            -> DualNumber d (Vector r)
            -> Int
            -> DualNumberInputs d r
            -> Int
            -> ( DualNumber d (Vector r)
               , DualNumber d (Vector r)
               , DualNumber d (Vector r) )
splitLayerV factivation hiddenVec offset inputs width =
  let multiplied = sumTrainableInputsS hiddenVec offset inputs width
      chunkWidth = width `div` 3
      activate :: Int -> DualNumber d (Vector r)
      activate n = do
        let v = V.slice (n * chunkWidth) chunkWidth multiplied
        factivation $ seq1 v + at1 inputs (offset + width + n)
      a0 = activate 0
      a1 = activate 1
      a2 = activate 2
  in (a0, a1, a2)

synthLossBareTotal
  :: forall d r. IsScalar d r
  => (DualNumber d (Vector r) -> DualNumber d (Vector r))
  -> (DualNumber d (Vector r) -> DualNumber d (Vector r))
  -> (DualNumber d (Vector r) -> DualNumber d (Vector r))
  -> Int
  -> Data.Vector.Storable.Vector (r, r)
  -> DualNumberInputs d r
  -> DualNumber d r
synthLossBareTotal factivation factivationHidden factivationMiddle
                   width samples inputs =
  let (datums, outputs) = V.unzip samples
      nSamples = V.length samples
      sampleData = datums <> outputs
      hiddenLayer1 = sumConstantDataL sampleData 0 inputs width
                     + at1 inputs width  -- bias
      nonlinearLayer1 = factivationHidden hiddenLayer1
      offsetMiddle = width + 1
      (ps1, ps2, ps3) =
        inline splitLayerV factivationMiddle nonlinearLayer1
                           offsetMiddle inputs (bloat * nSamples * 3)
  in inline synthLossAll factivation samples ps1 ps2 ps3


-- * Tests and generation of random data

-- Pair samples sorted and made unique wrt first element of the pair.
integerPairSamples :: (Storable r, Num r)
                   => (Int, Int) -> Int -> Int
                   -> Data.Vector.Storable.Vector (r, r)
integerPairSamples range seed k =
  let rolls :: RandomGen g => g -> [Int]
      rolls = unfoldr (Just . uniformR range)
      (g1, g2) = split $ mkStdGen seed
      nubInputs :: [Int] -> [Int] -> [Int]
      nubInputs candidates rest =
        let len = length candidates
        in if len == k
           then candidates
           else let (candidatesExtra, restExtra) = splitAt (k - len) rest
                    candidatesUniq = nub $ sort $ candidates ++ candidatesExtra
                in nubInputs candidatesUniq restExtra
      inputs = nubInputs [] (rolls g1)
  in V.zip (V.fromListN k $ map fromIntegral inputs)
           (V.fromListN k $ map fromIntegral $ rolls g2)

gradSmartTestCase
  :: forall r. (HasDelta r, r ~ Double)
  => String
  -> (Int
      -> Data.Vector.Storable.Vector (r, r)
      -> DualNumberInputs 'DModeGradient r
      -> DualNumber 'DModeGradient r)
  -> Int -> Int -> Int -> Int -> r
  -> TestTree
gradSmartTestCase prefix lossFunction seedSamples
                  nSamples width nIterations expected =
  let makeSamples s =
        integerPairSamples (-1000, 1000) (seedSamples + s) nSamples
      samples = map makeSamples [42, 49 .. 7 * nIterations]
      testSamples = map makeSamples [-1, -2 .. - 100]
      nParams1 = lenSynthV width nSamples
      -- Values from -0.5 to 0.5. TODO: start biases at 1
      params1Init =
        V.imap (\i nPV -> HM.randomVector (33 + nPV + i) HM.Uniform nPV
                          - HM.scalar 0.5)
               nParams1
      parametersInit = (V.empty, params1Init, V.empty, V.empty)
      name = prefix ++ " "
             ++ unwords [ show seedSamples, show nSamples, show width
                        , show (V.length nParams1), show (V.sum nParams1) ]
      f = lossFunction width
  in testCase name $ do
       (parametersResult, _) <-
         sgdAdam f samples parametersInit (initialStateAdam parametersInit)
       (_, values) <-
         unzip <$> mapM (\t -> dReverse 1 (f t) parametersResult) testSamples
       (sum values / 100) @?~ expected

conditionalSynthTests:: TestTree
conditionalSynthTests = do
 let f = inline synthLossBareTotal relu tanh tanh
 testGroup "synthesizing a sum of linear conditionals matching samples"
  [ gradSmartTestCase "relu"
      f 42 10 10  100
      4.740275311294229
  , gradSmartTestCase "relu"
      f 42 10 10  10000
      3.83451707827233e-2
  , gradSmartTestCase "relu"
      f 42 10 10  100000
      3.135485708489271e-2
  , gradSmartTestCase "relu"
      f 42 10 100 100000
      3.2872191198993095e-2
  ]
