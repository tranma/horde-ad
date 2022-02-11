{-# OPTIONS_GHC -Wno-missing-export-lists #-}
-- | Matrix-based (meaning that dual numbers for gradient computation
-- consider matrices, not scalars, as the primitive differentiable type)
-- implementation of fully connected neutral network for classification
-- of MNIST digits. Sports 2 hidden layers.
module HordeAd.Tool.MnistFcnnMatrix where

import Prelude

import           Control.Exception (assert)
import qualified Data.Strict.Vector as Data.Vector
import qualified Data.Vector.Generic as V
import           GHC.Exts (inline)
import           Numeric.LinearAlgebra (Numeric, Vector)

import HordeAd.Core.DualNumber
import HordeAd.Core.Engine
import HordeAd.Core.PairOfVectors (DualNumberVariables, varL, varV)
import HordeAd.Tool.MnistData

lenMnist2L :: Int -> Int -> Int
lenMnist2L _widthHidden _widthHidden2 = 0

lenVectorsMnist2L :: Int -> Int -> Data.Vector.Vector Int
lenVectorsMnist2L widthHidden widthHidden2 =
  V.fromList [widthHidden, widthHidden2, sizeMnistLabel]

lenMatrixMnist2L :: Int -> Int -> Data.Vector.Vector (Int, Int)
lenMatrixMnist2L widthHidden widthHidden2 =
  V.fromList $ [ (widthHidden, sizeMnistGlyph)
               , (widthHidden2, widthHidden)
               , (sizeMnistLabel, widthHidden2) ]

-- | Fully connected neural network for the MNIST digit classification task.
-- There are two hidden layers and both use the same activation function.
-- The output layer uses a different activation function.
-- The width of the layers is determined by the dimensions of the matrices
-- and vectors given as dual number parameters (variables).
-- The dimensions, in turn, can be computed by the @len*@ functions
-- on the basis of the requested widths, see above.
nnMnist2L :: (DeltaMonad r m, Numeric r, Num (Vector r))
          => (DualNumber (Vector r) -> m (DualNumber (Vector r)))
          -> (DualNumber (Vector r) -> m (DualNumber (Vector r)))
          -> Vector r
          -> DualNumberVariables r
          -> m (DualNumber (Vector r))
nnMnist2L factivationHidden factivationOutput input variables = do
  let !_A = assert (sizeMnistGlyph == V.length input) ()
      weightsL0 = varL variables 0
      biasesV0 = varV variables 0
      weightsL1 = varL variables 1
      biasesV1 = varV variables 1
      weightsL2 = varL variables 2
      biasesV2 = varV variables 2
  let hiddenLayer1 = weightsL0 #>!! input + biasesV0
  nonlinearLayer1 <- factivationHidden hiddenLayer1
  let hiddenLayer2 = weightsL1 #>! nonlinearLayer1 + biasesV1
  nonlinearLayer2 <- factivationHidden hiddenLayer2
  let outputLayer = weightsL2 #>! nonlinearLayer2 + biasesV2
  factivationOutput outputLayer

-- | The neural network applied to concrete activation functions
-- and composed with the appropriate loss function.
nnMnistLoss2L :: (DeltaMonad r m, Numeric r, Floating r, Floating (Vector r))
              => MnistData r
              -> DualNumberVariables r
              -> m (DualNumber r)
nnMnistLoss2L (input, target) variables = do
  result <- inline nnMnist2L logisticActV softMaxActV input variables
  lossCrossEntropyV target result

-- | The neural network applied to concrete activation functions
-- and composed with the appropriate loss function, using fused
-- softMax and cross entropy as the loss function.
nnMnistLossFused2L
  :: (DeltaMonad r m, Numeric r, Floating r, Floating (Vector r))
  => MnistData r
  -> DualNumberVariables r
  -> m (DualNumber r)
nnMnistLossFused2L (input, target) variables = do
  result <- inline nnMnist2L logisticActV (\x -> return x) input variables
  lossSoftMaxCrossEntropyV target result

-- | A function testing the neural network given testing set of inputs
-- and the trained parameters.
testMnist2L :: forall r. (Ord r, Floating r, Numeric r, Floating (Vector r))
            => [MnistData r] -> Domains r -> r
testMnist2L inputs parameters =
  let matchesLabels :: MnistData r -> Bool
      matchesLabels (glyph, label) =
        let nn = inline nnMnist2L logisticActV softMaxActV glyph
            value = primalValue nn parameters
        in V.maxIndex value == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)