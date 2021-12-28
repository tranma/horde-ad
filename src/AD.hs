{-# LANGUAGE FlexibleContexts, GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-missing-export-lists #-}
module AD where

import Prelude

import           Control.Monad (when)
import           Control.Monad.ST.Strict (ST)
import           Control.Monad.Trans.State.Strict
import qualified Data.Vector
import qualified Data.Vector.Generic as V
import qualified Data.Vector.Generic.Mutable as VM
import qualified Data.Vector.Unboxed

type Scalar = Float

type Domain = Vec Float  -- s

type Domain' = Domain  -- ds

type Codomain = Float  -- t

data Dual d = D Codomain d

type Vec a = Data.Vector.Unboxed.Vector a

type VecDualDelta = Data.Vector.Vector (Dual Delta)

newtype DeltaId = DeltaId Int
  deriving (Show, Eq, Ord, Enum)

-- Tagless final doesn't seem to work well, because we need to gather
-- @Delta@ while doing @Dual Delta@ operations, but evaluate on concrete
-- vectors that correspond to only the second component of dual numbers.
-- Also, initial encoding gives us full control over
-- when to evaluate. With final, we'd need to be careful
-- about laziness to ensure the optimal evaluation order is chosen
-- (whatever it is for a given differentiated program).
data Delta =
    Zero
  | Scale Scalar Delta
  | Add Delta Delta
  | Var DeltaId

-- This can't be environment in a Reader, because subtrees add their own
-- identifiers for sharing, instead of parents naming their subtrees.
-- This must be the "evaluate Let backwards" from SPJ's talk.
-- This and the need to control evaluation order contribute to
-- the difficulty of applying any HOAS concept instead of the monad
-- with bindings accumulated in state.
-- Note that each variable is created only once, but the subexpression
-- it's a part of can get duplicated grossly.
data DeltaState = DeltaState
  { deltaCounter  :: DeltaId
  , deltaBindings :: [(DeltaId, Delta)]
  }

newtype DeltaImplementation a = DeltaImplementation
  { runDeltaImplementation :: State DeltaState a }
  deriving (Monad, Functor, Applicative)

dlet :: Delta -> DeltaImplementation DeltaId
dlet v = DeltaImplementation $ do
  i <- gets deltaCounter
  modify $ \s ->
    s { deltaCounter = succ i
      , deltaBindings = (i, v) : deltaBindings s
      }
  return i

buildVector :: forall s v. VM.MVector (V.Mutable v) Float
            => VecDualDelta -> DeltaState -> Delta
            -> ST s (V.Mutable v s Float)
buildVector ds st d0 = do
  let DeltaId storeSize = deltaCounter st
  store <- VM.replicate storeSize 0
  let eval :: Scalar -> Delta -> ST s ()
      eval scale = \case
        Zero -> return ()
        Scale k d -> eval (k * scale) d
        Add d1 d2 -> eval scale d1 >> eval scale d2
        Var (DeltaId i) -> VM.modify store (+ scale) i
  eval 1 d0  -- dt is 1 or hardwired in f
  let evalUnlessZero :: (DeltaId, Delta) -> ST s ()
      evalUnlessZero (DeltaId i, d) = do
        scale <- store `VM.read` i
        when (scale /= 0) $
          eval scale d
  mapM_ evalUnlessZero (deltaBindings st)
  return $! VM.slice 0 (V.length ds) store

evalBindingsV :: VecDualDelta -> DeltaState -> Delta -> Domain'
evalBindingsV ds st d0 = V.create $ buildVector ds st d0

generalDf :: (s -> (VecDualDelta, Int))
          -> (VecDualDelta -> DeltaState -> Delta -> ds)
          -> (VecDualDelta -> DeltaImplementation (Dual Delta))
          -> s
          -> (ds, Codomain)
{-# INLINE generalDf #-}
generalDf initVars evalBindings f deltaInput =
  let ds :: VecDualDelta
      (ds, dim) = initVars deltaInput
      initialState = DeltaState
        { deltaCounter = DeltaId dim
        , deltaBindings = []
        }
      (D value d, st) = runState (runDeltaImplementation (f ds)) initialState
      res = evalBindings ds st d
  in (res, value)

df :: (VecDualDelta -> DeltaImplementation (Dual Delta))
   -> Domain
   -> (Domain', Codomain)
df =
  let initVars :: Domain -> (VecDualDelta, Int)
      initVars deltaInput =
        let dualizeInput i xi = D xi (Var $ DeltaId i)
        in ( V.fromList $ zipWith dualizeInput [0 ..] (V.toList deltaInput)
           , V.length deltaInput )
  in generalDf initVars evalBindingsV

gradDesc :: Scalar
         -> (VecDualDelta -> DeltaImplementation (Dual Delta))
         -> Int
         -> Domain
         -> Domain'
gradDesc gamma f = go where
  go :: Int -> Domain -> Domain'
  go 0 !vecInitial = vecInitial
  go n vecInitial =
    let res = fst $ df f vecInitial
        v = V.zipWith (\i r -> i - gamma * r) vecInitial res
    in go (pred n) v

(*\) :: Dual Delta -> Dual Delta -> DeltaImplementation (Dual Delta)
(*\) (D u u') (D v v') = do
  d <- dlet $ Add (Scale v u') (Scale u v')
  return $! D (u * v) (Var d)

(+\) :: Dual Delta -> Dual Delta -> DeltaImplementation (Dual Delta)
(+\) (D u u') (D v v') = do
  d <- dlet $ Add u' v'
  return $! D (u + v) (Var d)

(-\) :: Dual Delta -> Dual Delta -> DeltaImplementation (Dual Delta)
(-\) (D u u') (D v v') = do
  d <- dlet $ Add u' (Scale (-1) v')
  return $! D (u - v) (Var d)

(**\) :: Dual Delta -> Dual Delta -> DeltaImplementation (Dual Delta)
(**\) (D u u') (D v v') = do
  d <- dlet $ Add (Scale (v * (u ** (v - 1))) u')
                  (Scale ((u ** v) * log u) v')
  return $! D (u ** v) (Var d)

scalar :: Scalar -> Dual Delta
scalar k = D k Zero

_scale :: Scalar -> Dual Delta -> DeltaImplementation (Dual Delta)
_scale k (D u u') = do
  d <- dlet $ Scale k u'
  return $! D (k * u) (Var d)

tanhAct :: Dual Delta -> DeltaImplementation (Dual Delta)
tanhAct (D u u') = do
  let y = tanh u
  d <- dlet $ Scale (1 - y * y) u'
  return $! D y (Var d)

reluAct :: Dual Delta -> DeltaImplementation (Dual Delta)
reluAct (D u u') = do
  d <- dlet $ Scale (if u > 0 then 1 else 0) u'
  return $! D (max 0 u) (Var d)













-- higher order types of vars
-- recursion and recursive types
-- selective fusion of delta (for individual subfunctions: pre-computing,
--   inlining results and simplifying delta-expressions; the usual inlining
--   considerations apply)
-- checkpointing (limiting space usage?)
