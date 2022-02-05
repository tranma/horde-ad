{-# LANGUAGE FlexibleContexts #-}
-- | An ad-hoc representation of matrices that saves allocations and probably
-- speeds up computing gradients. The improvements are very likely tied
-- to the vagaries of hmatrix/blas/lapack that work underneath and apparently
-- conspire to fuse some matrix operations.
module HordeAd.Internal.MatrixOuter
  ( MatrixOuter (..)
  , nullMatrixOuter, convertMatrixOuter, toRowsMatrixOuter, plusMatrixOuter
  ) where

import Prelude

import qualified Data.Vector.Generic as V
import           Numeric.LinearAlgebra
  (Matrix, Numeric, Vector, asColumn, asRow, outer, toRows)
import qualified Numeric.LinearAlgebra

-- | A representation of a matrix as a product of a basic matrix
-- and an outer product of two vectors. Each component defaults to ones.
data MatrixOuter r = MatrixOuter (Maybe (Matrix r))
                                 (Maybe (Vector r)) (Maybe (Vector r))

nullMatrixOuter :: (MatrixOuter r) -> Bool
nullMatrixOuter (MatrixOuter Nothing Nothing Nothing) = True
nullMatrixOuter _ = False

convertMatrixOuter :: (Numeric r, Num (Vector r)) => MatrixOuter r -> Matrix r
convertMatrixOuter (MatrixOuter (Just m) Nothing Nothing) = m
convertMatrixOuter (MatrixOuter (Just m) (Just c) Nothing) = m * asColumn c
  -- beware, depending on context, @m * outer c (konst 1 (cols m))@
  -- may allocate much less and perhaps @fromRows . toRowsMatrixOuter@
  -- may be even better; that's probably blas fusing, but I can't see
  -- in hmatrix's code how it makes this possible;
  -- it doesn't matter if @m@ comes first
convertMatrixOuter (MatrixOuter (Just m) Nothing (Just r)) = m * asRow r
convertMatrixOuter (MatrixOuter (Just m) (Just c) (Just r)) = m * outer c r
convertMatrixOuter (MatrixOuter Nothing (Just c) (Just r)) = outer c r
convertMatrixOuter _ =
  error "convertMatrixOuter: dimensions can't be determined"

toRowsMatrixOuter :: (Numeric r, Num (Vector r)) => MatrixOuter r -> [Vector r]
toRowsMatrixOuter (MatrixOuter (Just m) Nothing Nothing) = toRows m
toRowsMatrixOuter (MatrixOuter (Just m) mc Nothing) =
  maybe id
        (\c -> zipWith (\s row -> Numeric.LinearAlgebra.scale s row)
                       (V.toList c))
        mc
  $ toRows m
toRowsMatrixOuter (MatrixOuter (Just m) mc (Just r)) =
  maybe (map (r *))
        (\c -> zipWith (\s row -> r * Numeric.LinearAlgebra.scale s row)
                       (V.toList c))
        mc
  $ toRows m
toRowsMatrixOuter (MatrixOuter Nothing (Just c) (Just r)) =
  map (`Numeric.LinearAlgebra.scale` r) $ V.toList c
toRowsMatrixOuter _ =
  error "toRowsMatrixOuter: dimensions can't be determined"

plusMatrixOuter :: (Numeric r, Num (Vector r))
                => MatrixOuter r -> MatrixOuter r -> MatrixOuter r
plusMatrixOuter o1 o2 =
  let !o = convertMatrixOuter o1 + convertMatrixOuter o2
  in MatrixOuter (Just o) Nothing Nothing
    -- TODO: Here we allocate up to 5 matrices, but we should allocate one
    -- and in-place add to it and multiply it, etc., ideally using raw FFI.