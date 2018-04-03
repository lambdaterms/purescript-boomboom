module Test.Main where

import Prelude

import Control.Monad.Aff (launchAff)
import Control.Monad.Eff.Class (liftEff)
import Test.BoomBoom.Strings as Test.BoomBoom.Strings
import Test.BoomBoom.Generic as Test.BoomBoom.Generic
import Test.BoomBoom.Generic.Interpret as Test.BoomBoom.Generic.Interpret
import Test.Unit (suite, test)
import Test.Unit.Assert (equal)
import Test.Unit.Console (TESTOUTPUT)
import Test.Unit.Main (runTest)


main = launchAff $ do
  liftEff <<< runTest $ do
    Test.BoomBoom.Strings.suite
    Test.BoomBoom.Generic.suite
    Test.BoomBoom.Generic.Interpret.suite
