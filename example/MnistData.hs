{-# LANGUAGE DataKinds, KindSignatures #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
-- | Parsing and pre-processing MNIST data.
module MnistData where

import Prelude

import           Codec.Compression.GZip (decompress)
import           Control.Arrow (first)
import           Data.Array.Internal (valueOf)
import qualified Data.Array.Shaped as OSB
import qualified Data.Array.ShapedS as OS
import qualified Data.ByteString.Lazy as LBS
import           Data.IDX
import           Data.List (sortOn)
import           Data.Maybe (fromMaybe)
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Unboxed
import           GHC.TypeLits
import           Numeric.LinearAlgebra (Matrix, Numeric, Vector)
import qualified Numeric.LinearAlgebra as LA
import           System.IO (IOMode (ReadMode), withBinaryFile)
import           System.Random

import HordeAd.Core.DualNumber

type SizeMnistWidth = 28 :: Nat

sizeMnistWidth :: StaticNat SizeMnistWidth
sizeMnistWidth = MkSN @SizeMnistWidth

sizeMnistWidthInt :: Int
sizeMnistWidthInt = staticNatValue sizeMnistWidth

type SizeMnistHeight = SizeMnistWidth

sizeMnistHeight :: StaticNat SizeMnistHeight
sizeMnistHeight = MkSN @SizeMnistHeight

type SizeMnistGlyph = SizeMnistWidth * SizeMnistHeight

sizeMnistGlyphInt :: Int
sizeMnistGlyphInt = valueOf @SizeMnistGlyph

type SizeMnistLabel = 10 :: Nat

sizeMnistLabel :: StaticNat SizeMnistLabel
sizeMnistLabel = MkSN @SizeMnistLabel

sizeMnistLabelInt :: Int
sizeMnistLabelInt = staticNatValue sizeMnistLabel

type LengthTestData = 10000 :: Nat

-- Actually, a better representation, supported by @Data.IDX@,
-- is an integer label and a picture (the same vector as below).
-- Then we'd use @lossCrossEntropy@ that picks a component according
-- to the label instead of performing a dot product with scaling.
-- This results in much smaller Delta expressions.
-- Our library makes this easy to express and gradients compute fine.
-- OTOH, methods with only matrix operations and graphs can't handle that.
-- However, the goal of the exercise it to implement the same
-- neural net that backprop uses for comparative benchmarks.
-- Also, loss computation is not the bottleneck and the more general
-- mechanism that admits non-discrete target labels fuses nicely
-- with softMax. This also seems to be the standard or at least
-- a simple default in tutorial.
type MnistData r = (Vector r, Vector r)

type MnistData2 r = (Matrix r, Vector r)

type MnistDataS r =
  ( OS.Array '[SizeMnistHeight, SizeMnistWidth] r
  , OS.Array '[SizeMnistLabel] r )

type MnistDataBatchS batch_size r =
  ( OS.Array '[batch_size, SizeMnistHeight, SizeMnistWidth] r
  , OS.Array '[batch_size, SizeMnistLabel] r )

shapeBatch :: Numeric r => MnistData r -> MnistDataS r
shapeBatch (input, target) = (OS.fromVector input, OS.fromVector target)

packBatch :: forall batch_size r. (Numeric r, KnownNat batch_size)
          => [MnistDataS r] -> MnistDataBatchS batch_size r
packBatch l =
  let (inputs, targets) = unzip l
  in (OS.ravel $ OSB.fromList inputs, OS.ravel $ OSB.fromList targets)

readMnistData :: LBS.ByteString -> LBS.ByteString -> [MnistData Double]
readMnistData glyphsBS labelsBS =
  let glyphs = fromMaybe (error "wrong MNIST glyphs file")
               $ decodeIDX glyphsBS
      labels = fromMaybe (error "wrong MNIST labels file")
               $ decodeIDXLabels labelsBS
      intData = fromMaybe (error "can't decode MNIST file into integers")
                $ labeledIntData labels glyphs
      f :: (Int, Data.Vector.Unboxed.Vector Int) -> MnistData Double
      -- Copied from library backprop to enable comparison of results.
      -- I have no idea how this is different from @labeledDoubleData@, etc.
      f (labN, v) =
        ( V.map (\r -> fromIntegral r / 255) $ V.convert v
        , V.generate sizeMnistLabelInt (\i -> if i == labN then 1 else 0) )
  in map f intData

trainGlyphsPath, trainLabelsPath, testGlyphsPath, testLabelsPath :: FilePath
trainGlyphsPath = "samplesData/train-images-idx3-ubyte.gz"
trainLabelsPath = "samplesData/train-labels-idx1-ubyte.gz"
testGlyphsPath  = "samplesData/t10k-images-idx3-ubyte.gz"
testLabelsPath  = "samplesData/t10k-labels-idx1-ubyte.gz"

loadMnistData :: FilePath -> FilePath -> IO [MnistData Double]
loadMnistData glyphsPath labelsPath =
  withBinaryFile glyphsPath ReadMode $ \glyphsHandle ->
    withBinaryFile labelsPath ReadMode $ \labelsHandle -> do
      glyphsContents <- LBS.hGetContents glyphsHandle
      labelsContents <- LBS.hGetContents labelsHandle
      return $! readMnistData (decompress glyphsContents)
                              (decompress labelsContents)

loadMnistData2 :: FilePath -> FilePath -> IO [MnistData2 Double]
loadMnistData2 glyphsPath labelsPath = do
  ds <- loadMnistData glyphsPath labelsPath
  return $! map (first $ LA.reshape sizeMnistWidthInt) ds

-- Good enough for QuickCheck, so good enough for me.
shuffle :: RandomGen g => g -> [a] -> [a]
shuffle g l =
  let rnds = randoms g :: [Int]
  in map fst $ sortOn snd $ zip l rnds

chunksOf :: Int -> [e] -> [[e]]
chunksOf n = go where
  go [] = []
  go l = let (chunk, rest) = splitAt n l
         in chunk : go rest
