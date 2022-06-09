{-# LANGUAGE CPP #-}
#if defined(VERSION_ghc_typelits_natnormalise)
-- Not really used here, but this squashes a warning caused by a hack
{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fplugin GHC.TypeLits.Normalise #-}
#endif
module Main (main) where

import Prelude

import qualified System.IO as SIO
import           Test.Tasty

#if defined(VERSION_ghc_typelits_natnormalise)
import qualified TestSimpleDescent
import qualified TestSingleGradient
#endif

main :: IO ()
main = do
  -- Limit interleaving of characters in parallel tests.
  SIO.hSetBuffering SIO.stdout SIO.LineBuffering
  SIO.hSetBuffering SIO.stderr SIO.LineBuffering
  defaultMain tests

tests :: TestTree
tests = testGroup "Minimal test that doesn't require any dataset" $
#if defined(VERSION_ghc_typelits_natnormalise)
  TestSingleGradient.testTrees
  ++ TestSimpleDescent.testTrees
#else
  []
#endif
