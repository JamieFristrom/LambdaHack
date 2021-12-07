module CommonMUnitTests (commonMUnitTests) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import Test.Tasty
import Test.Tasty.HUnit

import qualified Data.EnumMap.Strict as EM


import Game.LambdaHack.Client.CommonM

import Game.LambdaHack.Common.Area
import Game.LambdaHack.Common.Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.TileKind

import qualified Game.LambdaHack.Core.Dice as Dice

import UnitTestHelpers

testLevel :: Level
testLevel = Level
  { lkind = toEnum 0
  , ldepth = Dice.AbsDepth 1
  , lfloor = EM.empty
  , lembed = EM.empty
  , lbig = EM.empty
  , lproj = EM.empty
  , ltile = unknownTileMap (fromJust (toArea (0,0,0,0))) unknownId 10 10
  , lentry = EM.empty
  , larea = trivialArea (Point 0 0)
  , lsmell = EM.empty
  , lstair = ([],[])
  , lescape = []
  , lseen = 0
  , lexpl = 0
  , ltime = timeZero
  , lnight = False
  }

commonMUnitTests :: TestTree
commonMUnitTests = testGroup "commonMUnitTests" $
  [ testCase "getPerFid stubCliState returns emptyPerception" $
    do
      result <- executorCli (getPerFid testLevelId) stubCliState
      fst result @?= emptyPer
  , testCase "makeLine stubLevel fails" $
    do Nothing @?= makeLine False testActor (Point 0 0) 1 emptyCOps testLevel
  , testCase "makeLine unknownTiles succeeds" $
    do Just 1 @?= makeLine False testActor (Point 2 0) 1 emptyCOps testLevel
  ]
