{-# LANGUAGE AllowAmbiguousTypes, DataKinds, TypeFamilies, TypeOperators #-}
{-# OPTIONS_GHC -fconstraint-solver-iterations=16 #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
module TestMnistCNN (testTrees, shortTestForCITrees) where

import Prelude

import           Control.Monad (foldM)
import qualified Data.Array.DynamicS as OT
import           Data.Array.Internal (valueOf)
import qualified Data.Array.ShapedS as OS
import           Data.Proxy (Proxy (Proxy))
import qualified Data.Vector.Generic as V
import           GHC.TypeLits
  (KnownNat, SomeNat (..), someNatVal, type (+), type Div)
import qualified Numeric.LinearAlgebra as HM
import           System.Random
import           Test.Tasty
import           Test.Tasty.HUnit hiding (assert)
import           Test.Tasty.QuickCheck hiding (label, scale, shuffle)
import           Text.Printf

import HordeAd
import HordeAd.Tool.MnistTools

testTrees :: [TestTree]
testTrees = [ mnistCNNTestsShort
            , mnistCNNTestsLong
            ]

shortTestForCITrees :: [TestTree]
shortTestForCITrees = [ mnistCNNTestsShort
                      ]

-- * The simplest possible convolutional net, based on
-- https://www.ritchieng.com/machine-learning/deep-learning/tensorflow/convnets/#Problem-1
-- but with different initialization and no batches and the picture size
-- evolves differently (@conv2@ used instead of @convSame2@). Theirs is not
-- real convolution but, most likely, correlation, and their padding
-- only preserves size, while ours in @conv2@ increases it,
-- not to put less weigth onto information from the outer rows and columns.

patch_size, batch_size0, depth0, num_hidden0, final_image_size :: Int
patch_size = 5
batch_size0 = 16
depth0 = 16
num_hidden0 = 64
final_image_size = 10  -- if size was not increased: 7, see below

lenMnistCNN :: Int -> Int -> Int -> (Int, [Int], [(Int, Int)], [OT.ShapeL])
lenMnistCNN final_image_sz depth num_hidden =
  ( depth + depth
  , [num_hidden, sizeMnistLabel]
  , replicate (depth + depth * depth) (patch_size, patch_size)
    ++ [(num_hidden, final_image_sz * final_image_sz * depth)]
    ++ [(sizeMnistLabel, num_hidden)]
  , []
  )

-- This is simple convolution with depth 1.
convDataMnistCNN :: DualMonad r m
                 => DualNumberVariables r -> Primal (Tensor2 r) -> Int
                 -> m (DualNumber (Tensor2 r))
convDataMnistCNN variables x offset = do
  let ker = var2 variables offset
      bias = var0 variables offset
  yConv@(D u _) <- conv2 ker (D x (dKonst2 dZero (HM.size x)))  -- == (scalar x)
  yRelu <- reluAct2 $ yConv + konst2 bias (HM.size u)
  maxPool2 2 2 yRelu

-- This simulates convolution of nontrivial depth, without using tensors.
convMiddleMnistCNN :: DualMonad r m
                   => Int -> DualNumberVariables r
                   -> [DualNumber (Tensor2 r)] -> Int
                   -> m (DualNumber (Tensor2 r))
convMiddleMnistCNN depth variables ms1 k = do
  let conv (m, n) = do
        let ker = var2 variables ((1 + k) * depth + n)
        conv2 ker m
  ms2 <- mapM conv $ zip ms1 [0 ..]
  yConv@(D u _) <- returnLet $ sum ms2
  let bias = var0 variables (depth + k)
  yRelu <- reluAct2 $ yConv + konst2 bias (HM.size u)
  maxPool2 2 2 yRelu

convMnistCNN :: DualMonad r m
             => Int -> Primal (Tensor2 r)  -- 28x28
             -> DualNumberVariables r
             -> m (DualNumber (Tensor1 r))
convMnistCNN depth x variables = do
  ms1 <- mapM (convDataMnistCNN variables x) [0 .. depth - 1]
  ms3 <- mapM (convMiddleMnistCNN depth variables ms1) [0 .. depth - 1]
  let flattenAppend m = append1 (flatten1 m)
  v <- returnLet $ foldr flattenAppend (seq1 V.empty) ms3
  let weigthsDense = var2 variables (depth + depth * depth)
      biasesDense = var1 variables 0
      denseLayer = weigthsDense #>! v + biasesDense
  denseRelu <- reluAct1 denseLayer
  let weigthsReadout = var2 variables (depth + depth * depth + 1)
      biasesReadout = var1 variables 1
  returnLet $ weigthsReadout #>! denseRelu + biasesReadout

convMnistLossCNN :: (DualMonad r m, Floating (Primal (Tensor1 r)))
                 => Int -> MnistData2 (Primal r)
                 -> DualNumberVariables r
                 -> m (DualNumber r)
convMnistLossCNN depth (x, target) variables = do
  result <- convMnistCNN depth x variables
  lossSoftMaxCrossEntropyV target result

convMnistTestCNN
  :: forall r. (IsScalar r, Floating (Primal (Tensor1 r)))
  => Proxy r -> Int -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestCNN _ depth inputs parameters =
  let matchesLabels :: MnistData2 (Primal r) -> Bool
      matchesLabels (glyph, label) =
        let nn variables = do
              m <- convMnistCNN depth glyph variables
              softMaxActV m
            value = primalValue @r nn parameters
        in V.maxIndex value == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)
{-# SPECIALIZE convMnistTestCNN :: Proxy (Delta0 Double) -> Int -> [MnistData2 Double] -> Domains (Delta0 Double) -> Double #-}

-- Here, unlike in
-- https://www.ritchieng.com/machine-learning/deep-learning/tensorflow/convnets/#Problem-1
-- we don't batch yet.
convMnistTestCaseCNN
  :: String
  -> Int
  -> Int
  -> (Int
      -> MnistData2 Double
      -> DualNumberVariables (Delta0 Double)
      -> DualMonadGradient (Delta0 Double) (DualNumber (Delta0 Double)))
  -> (Proxy (Delta0 Double) -> Int -> [MnistData2 Double]
      -> Domains (Delta0 Double) -> Double)
  -> Int
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
convMnistTestCaseCNN prefix epochs maxBatches trainWithLoss testLoss
                     final_image_sz widthHidden widthHidden2 gamma expected =
  let ( (nParams0, nParams1, nParams2, nParamsX)
       , totalParams, range, parameters0 ) =
        initializerFixed 44 0.05
        (lenMnistCNN final_image_sz widthHidden widthHidden2)
      name = prefix ++ " "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show nParams1, show nParams2
                        , show nParamsX
                        , show totalParams, show gamma, show range]
  in testCase name $ do
       trainData <- loadMnistData2 trainGlyphsPath trainLabelsPath
       testData <- loadMnistData2 testGlyphsPath testLabelsPath
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: Domains (Delta0 Double)
                    -> (Int, [MnistData2 Double])
                    -> IO (Domains (Delta0 Double))
           runBatch (!params0, !params1, !params2, !paramsX) (k, chunk) = do
             printf "(Batch %d with %d points)\n" k (length chunk)
             let f = trainWithLoss widthHidden
                 res = fst $ sgd gamma f chunk
                                 (params0, params1, params2, paramsX)
                 trainScore = testLoss (Proxy @(Delta0 Double))
                                       widthHidden chunk res
                 testScore = testLoss (Proxy @(Delta0 Double))
                                      widthHidden testData res
             printf "Training error:   %.2f%%\n" ((1 - trainScore) * 100)
             printf "Validation error: %.2f%%\n" ((1 - testScore ) * 100)
             return res
       let runEpoch :: Int
                    -> Domains (Delta0 Double)
                    -> IO (Domains (Delta0 Double))
           runEpoch n params2 | n > epochs = return params2
           runEpoch n params2 = do
             printf "[Epoch %d]\n" n
             let trainDataShuffled = shuffle (mkStdGen $ n + 5) trainData
                 chunks = take maxBatches
                          $ zip [1 ..] $ chunksOf 5000 trainDataShuffled
             !res <- foldM runBatch params2 chunks
             runEpoch (succ n) res
       printf "\nEpochs to run/max batches per epoch: %d/%d\n"
              epochs maxBatches
       res <- runEpoch 1 parameters0
       let testErrorFinal = 1 - testLoss (Proxy @(Delta0 Double))
                                         widthHidden testData res
       testErrorFinal @?= expected


-- * Another flavour of the simplest possible convolutional net, based on
-- https://www.ritchieng.com/machine-learning/deep-learning/tensorflow/convnets/#Problem-1
-- but with different initialization and no batches.
-- Also, if @conv2@ was used instead of @convSame2@,
-- the picture size would evolve differently. Theirs is not
-- real convolution but, most likely, correlation, and their padding
-- only preserves size, while ours in @conv2@ increases it,
-- not to put less weigth onto information from the outer rows and columns.

final_image_sizeS :: Int
final_image_sizeS = 7

-- This is simple convolution with depth 1.
convDataMnistCNNS :: DualMonad r m
                  => DualNumberVariables r -> Primal (Tensor2 r) -> Int
                  -> m (DualNumber (Tensor2 r))
convDataMnistCNNS variables x offset = do
  let ker = var2 variables offset
      bias = var0 variables offset
  yConv@(D u _) <- convSame2 ker (scalar x)
  yRelu <- reluAct2 $ yConv + konst2 bias (HM.size u)
  maxPool2 2 2 yRelu

-- This simulates convolution of nontrivial depth, without using tensors.
convMiddleMnistCNNS :: DualMonad r m
                    => Int -> DualNumberVariables r
                    -> [DualNumber (Tensor2 r)] -> Int
                    -> m (DualNumber (Tensor2 r))
convMiddleMnistCNNS depth variables ms1 k = do
  let conv (m, n) = do
        let ker = var2 variables ((1 + k) * depth + n)
        convSame2 ker m
  ms2 <- mapM conv $ zip ms1 [0 ..]
  yConv@(D u _) <- returnLet $ sum ms2
  let bias = var0 variables (depth + k)
  yRelu <- reluAct2 $ yConv + konst2 bias (HM.size u)
  maxPool2 2 2 yRelu

convMnistCNNS :: DualMonad r m
              => Int -> Primal (Tensor2 r)  -- 28x28
              -> DualNumberVariables r
              -> m (DualNumber (Tensor1 r))
convMnistCNNS depth x variables = do
  ms1 <- mapM (convDataMnistCNNS variables x) [0 .. depth - 1]
  ms3 <- mapM (convMiddleMnistCNNS depth variables ms1) [0 .. depth - 1]
  let flattenAppend m = append1 (flatten1 m)
  v <- returnLet $ foldr flattenAppend (seq1 V.empty) ms3
  let weigthsDense = var2 variables (depth + depth * depth)
      biasesDense = var1 variables 0
      denseLayer = weigthsDense #>! v + biasesDense
  denseRelu <- reluAct1 denseLayer
  let weigthsReadout = var2 variables (depth + depth * depth + 1)
      biasesReadout = var1 variables 1
  returnLet $ weigthsReadout #>! denseRelu + biasesReadout

convMnistLossCNNS :: (DualMonad r m, Floating (Primal (Tensor1 r)))
                  => Int -> MnistData2 (Primal r)
                  -> DualNumberVariables r
                  -> m (DualNumber r)
convMnistLossCNNS depth (x, target) variables = do
  result <- convMnistCNNS depth x variables
  lossSoftMaxCrossEntropyV target result

convMnistTestCNNS
  :: forall r. (IsScalar r, Floating (Primal (Tensor1 r)))
  => Proxy r -> Int -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestCNNS _ depth inputs parameters =
  let matchesLabels :: MnistData2 (Primal r) -> Bool
      matchesLabels (glyph, label) =
        let nn variables = do
              m <- convMnistCNNS depth glyph variables
              softMaxActV m
            value = primalValue @r nn parameters
        in V.maxIndex value == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)
{-# SPECIALIZE convMnistTestCNNS :: Proxy (Delta0 Double) -> Int -> [MnistData2 Double] -> Domains (Delta0 Double) -> Double #-}


-- * A variant of @convMnistCNN@ with @conv2'@.

-- This is simple convolution with depth 1.
convDataMnistCNNP :: DualMonad r m
                  => DualNumberVariables r -> Primal (Tensor2 r) -> Int
                  -> m (DualNumber (Tensor2 r))
convDataMnistCNNP variables x offset = do
  let ker = var2 variables offset
      bias = var0 variables offset
  yConv@(D u _) <-
    returnLet $ conv2' ker (D x (dKonst2 dZero (HM.size x)))  -- == (scalar x)
  yRelu <- reluAct2 $ yConv + konst2 bias (HM.size u)
  maxPool2 2 2 yRelu

-- This simulates convolution of nontrivial depth, without using tensors.
convMiddleMnistCNNP :: DualMonad r m
                    => Int -> DualNumberVariables r
                    -> [DualNumber (Tensor2 r)] -> Int
                    -> m (DualNumber (Tensor2 r))
convMiddleMnistCNNP depth variables ms1 k = do
  let conv (m, n) = do
        let ker = var2 variables ((1 + k) * depth + n)
        returnLet $ conv2' ker m
  ms2 <- mapM conv $ zip ms1 [0 ..]
  yConv@(D u _) <- returnLet $ sum ms2
  let bias = var0 variables (depth + k)
  yRelu <- reluAct2 $ yConv + konst2 bias (HM.size u)
  maxPool2 2 2 yRelu

convMnistCNNP :: DualMonad r m
              => Int -> Primal (Tensor2 r)  -- 28x28
              -> DualNumberVariables r
              -> m (DualNumber (Tensor1 r))
convMnistCNNP depth x variables = do
  ms1 <- mapM (convDataMnistCNNP variables x) [0 .. depth - 1]
  ms3 <- mapM (convMiddleMnistCNNP depth variables ms1) [0 .. depth - 1]
  let flattenAppend m = append1 (flatten1 m)
  v <- returnLet $ foldr flattenAppend (seq1 V.empty) ms3
  let weigthsDense = var2 variables (depth + depth * depth)
      biasesDense = var1 variables 0
      denseLayer = weigthsDense #>! v + biasesDense
  denseRelu <- reluAct1 denseLayer
  let weigthsReadout = var2 variables (depth + depth * depth + 1)
      biasesReadout = var1 variables 1
  returnLet $ weigthsReadout #>! denseRelu + biasesReadout

convMnistLossCNNP :: (DualMonad r m, Floating (Primal (Tensor1 r)))
                  => Int -> MnistData2 (Primal r)
                  -> DualNumberVariables r
                  -> m (DualNumber r)
convMnistLossCNNP depth (x, target) variables = do
  result <- convMnistCNNP depth x variables
  lossSoftMaxCrossEntropyV target result

convMnistTestCNNP
  :: forall r. (IsScalar r, Floating (Primal (Tensor1 r)))
  => Proxy r -> Int -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestCNNP _ depth inputs parameters =
  let matchesLabels :: MnistData2 (Primal r) -> Bool
      matchesLabels (glyph, label) =
        let nn variables = do
              m <- convMnistCNNP depth glyph variables
              softMaxActV m
            value = primalValue @r nn parameters
        in V.maxIndex value == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)
{-# SPECIALIZE convMnistTestCNNP :: Proxy (Delta0 Double) -> Int -> [MnistData2 Double] -> Domains (Delta0 Double) -> Double #-}


-- * A variant of @convMnistCNN@ with shaped tensors, including mini-batches.

lenMnistCNNT :: Int -> Int -> Int -> (Int, [Int], [(Int, Int)], [OT.ShapeL])
lenMnistCNNT final_image_sz depth num_hidden =
  ( 0
  , [num_hidden, sizeMnistLabel]
  , [ (num_hidden, final_image_sz * final_image_sz * depth)
    , (sizeMnistLabel, num_hidden) ]
  , [ [depth, 1, patch_size, patch_size]
    , [depth, depth, patch_size, patch_size]
    , [depth], [depth] ]
 )

convMiddleMnistCNNT
  :: forall in_height in_width kheight_minus_1 kwidth_minus_1 out_channels
            n_batches in_channels r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat n_batches, KnownNat in_channels
     , DualMonad r m )
  => DualNumber (TensorS r '[ out_channels, in_channels
                            , kheight_minus_1 + 1, kwidth_minus_1 + 1 ])
  -> DualNumber (TensorS r '[n_batches, in_channels, in_height, in_width])
  -> DualNumber (TensorS r '[out_channels])
  -> m (DualNumber (TensorS r '[ n_batches, out_channels
                               , (in_height + kheight_minus_1) `Div` 2
                               , (in_width + kwidth_minus_1) `Div` 2 ]))
convMiddleMnistCNNT ker x bias = do
  let yConv = conv24 ker x
      replicateBias
        :: DualNumber (TensorS r '[])
           -> DualNumber (TensorS r '[ in_height + kheight_minus_1
                                     , in_width + kwidth_minus_1 ])
      replicateBias = konstS . fromS0
      biasStretched = ravelFromListS
                      $ replicate (valueOf @n_batches)
                      $ mapS replicateBias bias
        -- TODO: this is weakly typed; add and use replicateS instead
  yRelu <- reluActS $ yConv + biasStretched
  maxPool24 @2 @2 yRelu

convMnistCNNT
  :: forall kheight_minus_1 kwidth_minus_1
            in_height in_width out_channels in_channels n_batches r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat n_batches, KnownNat in_channels
     , DualMonad r m )
  => Primal (TensorS r '[n_batches, in_channels, in_height, in_width])
  -> DualNumberVariables r
  -> m (DualNumber (Tensor2 r))
convMnistCNNT x variables = do
  let ker1 :: DualNumber (TensorS r '[ out_channels, in_channels
                                     , kheight_minus_1 + 1
                                     , kwidth_minus_1 + 1 ])
      ker1 = varS variables 0
      bias1 = varS variables 2
  t1 <- convMiddleMnistCNNT ker1 (scalar x) bias1
  let ker2 :: DualNumber (TensorS r '[ out_channels, out_channels
                                     , kheight_minus_1 + 1
                                     , kwidth_minus_1 + 1 ])
      ker2 = varS variables 1
      bias2 = varS variables 3
  t2 <- convMiddleMnistCNNT ker2 t1 bias2
  let m1 = mapS reshapeS t2
      m2 = fromS2 m1
      -- From this point on I give up and move from shaped tensors
      -- to untyped matrices and vectors. We need shaped matrix
      -- multiplication, etc., to carry on with strict types there.
      weigthsDense = var2 variables 0
      biasesDense = var1 variables 0
      denseLayer = weigthsDense <>! transpose2 m2
                   + asColumn2 biasesDense (valueOf @n_batches)
  denseRelu <- reluAct2 denseLayer
  let weigthsReadout = var2 variables 1
      biasesReadout = var1 variables 1
  returnLet $ weigthsReadout <>! denseRelu
                                 + asColumn2 biasesReadout (valueOf @n_batches)

convMnistLossCNNTPoly
  :: forall kheight_minus_1 kwidth_minus_1
            in_height in_width in_channels out_channels n_batches r m.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat n_batches, KnownNat in_channels
     , DualMonad r m, Floating (Primal (Tensor2 r)) )
  => [MnistData2 (Primal r)]
  -> DualNumberVariables r
  -> m (DualNumber r)
convMnistLossCNNTPoly lmnistData variables = do
  let (lx, ltarget) = unzip lmnistData
      tx :: Primal (TensorS r '[n_batches, in_channels, in_height, in_width])
      tx = OS.fromList $ concatMap (HM.toList . HM.flatten) lx
  result <- convMnistCNNT @kheight_minus_1 @kwidth_minus_1
                          @in_height @in_width @out_channels
                          tx variables
  vec@(D u _) <- lossSoftMaxCrossEntropyL (HM.fromColumns ltarget) result
  returnLet $ scale (recip $ fromIntegral $ V.length u) $ sumElements0 vec

convMnistLossCNNT
  :: forall kheight_minus_1 kwidth_minus_1
            in_height in_width in_channels out_channels n_batches r m.
     ( DualMonad r m, Floating (Primal (Tensor2 r))
     , n_batches ~ 16
     , out_channels ~ 16
     , kheight_minus_1 ~ 4
     , kwidth_minus_1 ~ 4
     , in_height ~ 28
     , in_width ~ 28
     , in_channels ~ 1
     )
  => [MnistData2 (Primal r)]
  -> DualNumberVariables r
  -> m (DualNumber r)
convMnistLossCNNT =
  convMnistLossCNNTPoly
    @kheight_minus_1 @kwidth_minus_1 @in_height @in_width
    @in_channels @out_channels @n_batches

convMnistTestCNNTPoly
  :: forall kheight_minus_1 kwidth_minus_1
            in_height in_width in_channels out_channels n_batches r.
     ( KnownNat kheight_minus_1, KnownNat kwidth_minus_1, KnownNat out_channels
     , KnownNat in_height, KnownNat in_width
     , KnownNat n_batches, KnownNat in_channels
     , IsScalar r, Floating (Primal (Tensor1 r)) )
  => Proxy r -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestCNNTPoly _ inputs parameters =
  let matchesLabels :: MnistData2 (Primal r) -> Bool
      matchesLabels (glyph, label) =
        let tx :: Primal (TensorS r '[ n_batches, in_channels
                                     , in_height, in_width ])
            tx = OS.fromVector $ HM.flatten glyph
            nn :: DualNumberVariables r
               -> DualMonadValue r (DualNumber (Tensor1 r))
            nn variables = do
              m <- convMnistCNNT
                          @kheight_minus_1 @kwidth_minus_1
                          @in_height @in_width @out_channels
                          tx variables
              softMaxActV $ flatten1 m
            value = primalValue @r nn parameters
        in V.maxIndex value == V.maxIndex label
  in fromIntegral (length (filter matchesLabels inputs))
     / fromIntegral (length inputs)

convMnistTestCNNT
  :: forall kheight_minus_1 kwidth_minus_1
            in_height in_width in_channels out_channels n_batches r.
     ( IsScalar r, Floating (Primal (Tensor1 r))
     , n_batches ~ 1
     , out_channels ~ 16
     , kheight_minus_1 ~ 4
     , kwidth_minus_1 ~ 4
     , in_height ~ 28
     , in_width ~ 28
     , in_channels ~ 1
     )
  => Proxy r -> [MnistData2 (Primal r)] -> Domains r -> Primal r
convMnistTestCNNT =
  convMnistTestCNNTPoly
    @kheight_minus_1 @kwidth_minus_1 @in_height @in_width
    @in_channels @out_channels @n_batches

convMnistTestCaseCNNT
  :: String
  -> Int
  -> Int
  -> ([MnistData2 Double]
      -> DualNumberVariables (Delta0 Double)
      -> DualMonadGradient (Delta0 Double) (DualNumber (Delta0 Double)))
  -> (Proxy (Delta0 Double)
      -> [MnistData2 Double] -> Domains (Delta0 Double) -> Double)
  -> Int
  -> Int
  -> Int
  -> Int
  -> Double
  -> Double
  -> TestTree
convMnistTestCaseCNNT prefix epochs maxBatches trainWithLoss testLoss
                      final_image_sz widthHidden widthHidden2 batch_size
                      gamma expected =
  let ( (nParams0, nParams1, nParams2, nParamsX)
       , totalParams, range, parameters0 ) =
        initializerFixed 44 0.05
        (lenMnistCNNT final_image_sz widthHidden widthHidden2)
      name = prefix ++ " "
             ++ unwords [ show epochs, show maxBatches
                        , show widthHidden, show widthHidden2
                        , show nParams0, show nParams1, show nParams2
                        , show nParamsX
                        , show totalParams, show gamma, show range]
  in testCase name $ do
       trainData <- loadMnistData2 trainGlyphsPath trainLabelsPath
       testData <- take 100 <$> loadMnistData2 testGlyphsPath testLabelsPath
       -- Mimic how backprop tests and display it, even though tests
       -- should not print, in principle.
       let runBatch :: Domains (Delta0 Double)
                    -> (Int, [MnistData2 Double])
                    -> IO (Domains (Delta0 Double))
           runBatch (!params0, !params1, !params2, !paramsX) (k, chunk) = do
             printf "(Batch %d with %d points)\n" k (length chunk)
             let f = trainWithLoss
                 res = fst $ sgd gamma f (chunksOf batch_size chunk)
                                 (params0, params1, params2, paramsX)
                 trainScore = testLoss (Proxy @(Delta0 Double)) chunk res
                 testScore = testLoss (Proxy @(Delta0 Double)) testData res
             printf "Training error:   %.2f%%\n" ((1 - trainScore) * 100)
             printf "Validation error: %.2f%%\n" ((1 - testScore ) * 100)
             return res
       let runEpoch :: Int
                    -> Domains (Delta0 Double)
                    -> IO (Domains (Delta0 Double))
           runEpoch n params2 | n > epochs = return params2
           runEpoch n params2 = do
             printf "[Epoch %d]\n" n
             let trainDataShuffled = shuffle (mkStdGen $ n + 5) trainData
                 chunks = take maxBatches
                          $ zip [1 ..] $ chunksOf (2 * batch_size)
                                                  trainDataShuffled
                          -- TODO: 5000 takes forever
             !res <- foldM runBatch params2 chunks
             runEpoch (succ n) res
       printf "\nEpochs to run/max batches per epoch: %d/%d\n"
              epochs maxBatches
       res <- runEpoch 1 parameters0
       let testErrorFinal = 1 - testLoss (Proxy @(Delta0 Double)) testData res
       testErrorFinal @?= expected

mnistCNNTestsLong :: TestTree
mnistCNNTestsLong = testGroup "MNIST CNN long tests"
  [ {-convMnistTestCaseCNN "artificial 5 4 3 2 1" 5 4
                         convMnistLossCNN convMnistTestCNN final_image_size
                         3 2 1 0.8991
  , convMnistTestCaseCNN "S artificial 5 4 3 2 1" 5 4
                         convMnistLossCNNS convMnistTestCNNS final_image_sizeS
                         3 2 1 0.8991
  , -}convMnistTestCaseCNN "P artificial 5 4 3 2 1" 5 4
                         convMnistLossCNNP convMnistTestCNNP final_image_size
                         3 2 1 0.8991
  , convMnistTestCaseCNNT "T artificial 5 4 3 2 1" 5 4
                          (convMnistLossCNNTPoly @4 @4 @28 @28 @1 @3 @1)
                          (convMnistTestCNNTPoly @4 @4 @28 @28 @1 @3 @1)
                          final_image_size
                          3 2 1 0.02 0.98
  , convMnistTestCaseCNN "1 epoch 1 batch" 1 1
                         convMnistLossCNN convMnistTestCNN
                         final_image_size depth0 num_hidden0
                         0.02 5.989999999999995e-2
{-
  , convMnistTestCaseCNN "2 epochs but only 1 batch" 2 1
                         convMnistLossCNN convMnistTestCNN
                         final_image_size depth0 num_hidden0
                         0.02 8.879999999999999e-2  -- dummy results everywhere
  , convMnistTestCaseCNN "1 epoch all batches" 1 99
                         convMnistLossCNN convMnistTestCNN
                         final_image_size depth0 num_hidden0
                         0.02 5.1100000000000034e-2
-}
  , convMnistTestCaseCNN "S1 epoch 1 batch" 1 1
                         convMnistLossCNNS convMnistTestCNNS
                         final_image_sizeS depth0 num_hidden0
                         0.02 4.800000000000004e-2
{-
  , convMnistTestCaseCNN "S2 epochs but only 1 batch" 2 1
                         convMnistLossCNNS convMnistTestCNNS
                         final_image_sizeS depth0 num_hidden0
                         0.02 8.879999999999999e-2
  , convMnistTestCaseCNN "S1 epoch all batches" 1 99
                         convMnistLossCNNS convMnistTestCNNS
                         final_image_sizeS depth0 num_hidden0
                         0.02 5.1100000000000034e-2
-}
  , convMnistTestCaseCNN "P1 epoch 1 batch" 1 1
                         convMnistLossCNNP convMnistTestCNNP
                         final_image_size depth0 num_hidden0
                         0.02 5.989999999999995e-2
{-
  , convMnistTestCaseCNN "P2 epochs but only 1 batch" 2 1
                         convMnistLossCNNP convMnistTestCNNP
                         final_image_size depth0 num_hidden0
                         0.02 4.94e-2
  , convMnistTestCaseCNN "P1 epoch all batches" 1 99
                         convMnistLossCNNP convMnistTestCNNP
                         final_image_size depth0 num_hidden0
                         0.02 2.7000000000000024e-2
-}
  , convMnistTestCaseCNNT "T1 epoch 1 batch" 1 1
                          convMnistLossCNNT convMnistTestCNNT
                          final_image_size depth0 num_hidden0
                          batch_size0 0.02 0.98
  , testProperty "Compare gradients and two forward derivatives for a single 2d convolution implemented from primitive operations and as a hardwired primitive" $
      forAll (choose (1, 30)) $ \seed ->
      forAll (choose (1, 50)) $ \seedDs ->
      forAll (choose (1, 100)) $ \widthHidden ->
      forAll (choose (1, 150)) $ \widthHidden2 ->
      forAll (choose (0, seed + widthHidden - 2)) $ \ix1 ->
      forAll (choose (0, seedDs + widthHidden2 - 2)) $ \ix2 ->
      forAll (choose (0.01, 10)) $ \range ->
      forAll (choose (0.01, 10)) $ \rangeDs ->
        let paramShape =
              (0, [], [(seed, widthHidden2), (widthHidden, seedDs)], [])
            (_, _, _, parameters) = initializerFixed seed range paramShape
            (_, _, _, ds@(ds0, ds1, ds2, dsX)) =
              initializerFixed seedDs rangeDs paramShape
            (_, _, _, parametersPerturbation) =
              initializerFixed (seed + seedDs) 1e-7 paramShape
            f, fP :: forall r m. (DualMonad r m, Primal r ~ Double)
                  => DualNumberVariables r -> m (DualNumber r)
            f variables = do
              let ker = var2 variables 0
                  x = var2 variables 1
              c <- conv2 ker x
              cx <- returnLet $ from2X c
              cx1 <- returnLet $ indexX cx ix1
              cx2 <- returnLet $ indexX cx1 ix2
              returnLet $ fromX0 cx2
            fP variables = do
              let ker = var2 variables 0
                  x = var2 variables 1
              c <- returnLet $ conv2' ker x
              cx <- returnLet $ from2X c
              cx1 <- returnLet $ indexX cx ix1
              cx2 <- returnLet $ indexX cx1 ix2
              returnLet $ fromX0 cx2
            ff = dFastForward f parameters ds
            ffP@(_, ffPValue) = dFastForward fP parameters ds
            perturbedffP@(_, perturbedffPValue) =
              dFastForward fP parameters parametersPerturbation
            close a b = abs (a - b) <= 1e-4
            close1 (a1, b1) (a2, b2) = close a1 a2 .&&. b1 === b2
            dfDot fDot psDot =
              let ((res0, res1, res2, resX), value) = dReverse fDot psDot
              in ( res0 HM.<.> ds0
                   + V.sum (V.zipWith (HM.<.>) res1 ds1)
                   + V.sum (V.zipWith (HM.<.>) (V.map HM.flatten res2)
                                               (V.map HM.flatten ds2))
                   + V.sum (V.zipWith (HM.<.>) (V.map OT.toVector resX)
                                               (V.map OT.toVector dsX))
                 , value )
            addParams (a0, a1, a2, aX) (b0, b1, b2, bX) =
              ( a0 + b0, V.zipWith (+) a1 b1, V.zipWith (+) a2 b2
              , V.zipWith (+) aX bX )
        in ffPValue == perturbedffPValue
           .&&. close1 ff ffP
           .&&. dForward f parameters ds === ff
           .&&. close1 (dfDot f parameters) ff
           .&&. dForward fP parameters ds === ffP
           .&&. close1 (dfDot fP parameters) ffP
           .&&. close (primalValue @(Delta0 Double) @(Delta0 Double)
                                   fP (addParams parameters
                                                 parametersPerturbation))
                      (ffPValue + fst perturbedffP)
  , testProperty "Compare gradients and two forward derivatives for convMnistTestCNN and convMnistTestCNNP" $
      \seed ->
      forAll (choose (0, sizeMnistLabel - 1)) $ \seedDs ->
      forAll (choose (1, 20)) $ \depth ->
      forAll (choose (1, 30)) $ \num_hidden ->
      forAll (choose (0.01, 0.5)) $ \range ->
      forAll (choose (0.01, 10)) $ \rangeDs ->
        let createRandomVector n seedV = HM.randomVector seedV HM.Uniform n
            glyph = HM.reshape 28 $ createRandomVector (28 * 28) seed
            label = HM.konst 0 sizeMnistLabel V.// [(seedDs, 1)]
            mnistData :: MnistData2 Double
            mnistData = (glyph, label)
            paramShape = lenMnistCNN final_image_size depth num_hidden
            (_, _, _, parameters) = initializerFixed seed range paramShape
            (_, _, _, ds) = initializerFixed seedDs rangeDs paramShape
            (_, _, _, parametersPerturbation) =
              initializerFixed (seed + seedDs) 1e-7 paramShape
            f, fP, fT :: forall r m. (DualMonad r m, Primal r ~ Double)
                  => DualNumberVariables r -> m (DualNumber r)
            f = convMnistLossCNN depth mnistData
            fP = convMnistLossCNNP depth mnistData
            fT = case someNatVal $ toInteger depth of
              Just (SomeNat (_ :: Proxy out_channel)) ->
                convMnistLossCNNTPoly @4 @4 @28 @28 @1 @out_channel @1
                                      [mnistData]
              Nothing -> error "fT panic"
            paramsToT (p0, p1, p2, _) =
              let q2 = V.drop (depth + depth * depth) p2
                  qX = V.fromList
                    [ OT.fromVector [depth, 1, 5, 5]
                      $ V.concat $ map HM.flatten
                      $ take depth $ V.toList p2
                    , OT.fromVector [depth, depth, 5, 5]
                      $ V.concat $ map HM.flatten
                      $ take (depth * depth) (drop depth $ V.toList p2)
                    , OT.fromVector [depth] $ V.take depth p0
                    , OT.fromVector [depth] $ V.drop depth p0
                    ]
              in (V.empty, p1, q2, qX)
            parametersT = paramsToT parameters
            dsT = paramsToT ds
            ff = dFastForward f parameters ds
            ffP@(_, ffPValue) = dFastForward fP parameters ds
            perturbedffP@(_, perturbedffPValue) =
              dFastForward fP parameters parametersPerturbation
            ffT = dFastForward fT parametersT dsT
            close a b = abs (a - b) <= 1e-4
            close1 (a1, b1) (a2, b2) = close a1 a2 .&&. b1 === b2
            dfDot fDot psDot (ds0, ds1, ds2, dsX) =
              let ((res0, res1, res2, resX), value) = dReverse fDot psDot
              in ( res0 HM.<.> ds0
                   + V.sum (V.zipWith (HM.<.>) res1 ds1)
                   + V.sum (V.zipWith (HM.<.>) (V.map HM.flatten res2)
                                               (V.map HM.flatten ds2))
                   + V.sum (V.zipWith (HM.<.>) (V.map OT.toVector resX)
                                               (V.map OT.toVector dsX))
                 , value )
            addParams (a0, a1, a2, aX) (b0, b1, b2, bX) =
              ( a0 + b0, V.zipWith (+) a1 b1, V.zipWith (+) a2 b2
              , V.zipWith (+) aX bX )
        in close1 ff ffP
           .&&. close1 ff ffT
           .&&. dForward f parameters ds === ff
           .&&. close1 (dfDot f parameters ds) ff
           .&&. dForward fP parameters ds === ffP
           .&&. close1 (dfDot fP parameters ds) ffP
           .&&. dForward fT parametersT dsT === ffT
           .&&. close1 (dfDot fT parametersT dsT) ffT
           .&&. ffPValue == perturbedffPValue
           .&&. close (primalValue @(Delta0 Double) @(Delta0 Double)
                                   fP (addParams parameters
                                                 parametersPerturbation))
                      (ffPValue + fst perturbedffP)
  ]

mnistCNNTestsShort :: TestTree
mnistCNNTestsShort = testGroup "MNIST CNN short tests"
  [ convMnistTestCaseCNN "artificial 1 1 1 1 1" 1 1
                         convMnistLossCNN convMnistTestCNN final_image_size
                         1 1 1 0.9026
  , convMnistTestCaseCNN "S artificial 1 1 1 1 1" 1 1
                         convMnistLossCNNS convMnistTestCNNS final_image_sizeS
                         1 1 1 0.9026
  , convMnistTestCaseCNN "P artificial 1 1 1 1 1" 1 1
                         convMnistLossCNNP convMnistTestCNNP final_image_size
                         1 1 1 0.9026
  , convMnistTestCaseCNNT "T artificial 1 1 1 1 1" 1 1
                          (convMnistLossCNNTPoly @4 @4 @28 @28 @1 @1 @1)
                          (convMnistTestCNNTPoly @4 @4 @28 @28 @1 @1 @1)
                          final_image_size
                          1 1 1 1 0.85
{-
  , convMnistTestCaseCNN "artificial 1 2 3 4 5" 1 2
                         convMnistLossCNN convMnistTestCNN final_image_size
                         3 4 5 0.902
  , convMnistTestCaseCNN "S artificial 1 2 3 4 5" 1 2
                         convMnistLossCNNS convMnistTestCNNS final_image_sizeS
                         3 4 5 0.902
  , convMnistTestCaseCNN "P artificial 1 2 3 4 5" 1 2
                         convMnistLossCNNP convMnistTestCNNP final_image_size
                         3 4 5 0.8972
-}
  , convMnistTestCaseCNNT "T artificial 1 2 3 4 5" 1 2
                          (convMnistLossCNNTPoly @4 @4 @28 @28 @1 @3 @5)
                          (convMnistTestCNNTPoly @4 @4 @28 @28 @1 @3 @1)
                          final_image_size
                          3 4 5 6 0.92
  ]
