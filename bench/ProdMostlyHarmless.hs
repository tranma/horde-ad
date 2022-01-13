module Main (main) where

import Prelude

import           Criterion.Main
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Unboxed
import           System.Random

import AD

main :: IO ()
main = do
  let allxs = map (+ 0.55) $ randoms (mkStdGen 42) :: [Double]
      vec100 = V.fromList $ take 100 allxs
      vec200 = V.fromList $ take 200 allxs
      vec1000 = V.fromList $ take 1000 allxs
      vec10e5 = V.fromList $ take 100000 allxs
      vec10e6 = V.fromList $ take 1000000 allxs
      vec10e7 = V.fromList $ take 10000000 allxs
      vecHalf10e8 = V.fromList $ take 50000000 allxs
  defaultMain
    [ bgroup "100"
        [ bench "vec_func" $ nf vec_prod vec100
        , bench "vec_grad" $ nf vec_grad_prod vec100
        , bench "toList_grad" $ nf toList_grad_prod (take 100 allxs)
        ]
    , bgroup "200"
        [ bench "vec_func" $ nf vec_prod vec200
        , bench "vec_grad" $ nf vec_grad_prod vec200
        , bench "toList_grad" $ nf toList_grad_prod (take 200 allxs)
        ]
    , bgroup "1000"
        [ bench "vec_func" $ nf vec_prod vec1000
        , bench "vec_grad" $ nf vec_grad_prod vec1000
        , bench "toList_grad" $ nf toList_grad_prod (take 1000 allxs)
        ]
    , bgroup "10e5"
        [ bench "vec_func" $ nf vec_prod vec10e5
        , bench "vec_grad" $ nf vec_grad_prod vec10e5
        , bench "toList_grad" $ nf toList_grad_prod (take 100000 allxs)
        ]
    , bgroup "10e6"
        [ bench "vec_func" $ nf vec_prod vec10e6
        , bench "vec_grad" $ nf vec_grad_prod vec10e6
        , bench "toList_grad" $ nf toList_grad_prod (take 1000000 allxs)
        ]
    , bgroup "10e7"
        [ bench "vec_func" $ nf vec_prod vec10e7
        , bench "vec_grad" $ nf vec_grad_prod vec10e7
        , bench "toList_grad" $ nf toList_grad_prod (take 10000000 allxs)
        ]
    , bgroup "Half10e8"
        [ bench "vec_func" $ nf vec_prod vecHalf10e8
        , bench "vec_grad" $ nf vec_grad_prod vecHalf10e8  -- 11.47s
-- this already takes 35G, so the worse variants not attempted:
--        , bench "toList_grad" $ nf toList_grad_prod (take 50000000 allxs)
        ]
    ]

vec_prod_aux :: forall m r. (DeltaMonad r m, Num r, Data.Vector.Unboxed.Unbox r)
             => VecDualDelta r -> m (DualDelta r)
vec_prod_aux vec = do
  let f :: DualDelta r -> Int -> r -> m (DualDelta r)
      f !acc !i !valX = do
        -- An awkard use of internals that can't be avoided without
        -- some other awkward bits of code and an extra performance hit.
        -- The whole business with @vec@ being a pair of vectors,
        -- instead of one vector, is an optimization for gradient descent,
        -- which works fine there, but costs us some cycles and clarity here,
        -- where there's no gradient descent to manage the vectors.
        let x = D valX (snd vec V.! i)
        acc *\ x  -- no handwritten gradients; only gradient for * is provided
  V.ifoldM' f (scalar 1) $ fst vec

vec_grad_prod :: (Eq r, Num r, Data.Vector.Unboxed.Unbox r)
              => Domain r -> Domain' r
vec_grad_prod = fst . df vec_prod_aux

vec_prod :: (Num r, Data.Vector.Unboxed.Unbox r)
         => Domain r -> r
vec_prod = valueDualDelta vec_prod_aux

toList_grad_prod :: (Eq r, Num r, Data.Vector.Unboxed.Unbox r)
                 => [r] -> [r]
toList_grad_prod l = V.toList $ vec_grad_prod $ V.fromList l
