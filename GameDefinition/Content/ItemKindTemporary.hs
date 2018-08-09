-- | Temporary aspect pseudo-item definitions.
module Content.ItemKindTemporary
  ( temporaries
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Color
import Game.LambdaHack.Common.Dice
import Game.LambdaHack.Common.Flavour
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Content.ItemKind

temporaries :: [ItemKind]
temporaries =
  [tmpStrengthened, tmpWeakened, tmpProtectedMelee, tmpProtectedRanged, tmpVulnerable, tmpResolute, tmpFast20, tmpSlow10, tmpFarSighted, tmpBlind, tmpKeenSmelling, tmpNoctovision, tmpDrunk, tmpRegenerating, tmpPoisoned, tmpSlow10Resistant, tmpPoisonResistant]

tmpStrengthened,    tmpWeakened, tmpProtectedMelee, tmpProtectedRanged, tmpVulnerable, tmpResolute, tmpFast20, tmpSlow10, tmpFarSighted, tmpBlind, tmpKeenSmelling, tmpNoctovision, tmpDrunk, tmpRegenerating, tmpPoisoned, tmpSlow10Resistant, tmpPoisonResistant :: ItemKind

-- The @name@ is be used in item description, so it should be an adjective
-- describing the temporary set of aspects.
tmpAspects :: Text -> [Aspect] -> ItemKind
tmpAspects name aspects = ItemKind
  { isymbol  = '+'
  , iname    = name
  , ifreq    = [(toGroupName name, 1), ("condition", 1)]
  , iflavour = zipPlain [BrWhite]
  , icount   = 1
  , irarity  = [(1, 1)]
  , iverbHit = "affect"
  , iweight  = 0
  , idamage  = 0
  , iaspects = -- timeout is 0; activates and vanishes soon,
               -- depending on initial timer setting
               aspects
               ++ [SetFlag Periodic, SetFlag Fragile, SetFlag Durable]
                    -- hack: destroy on drop
  , ieffects = [ Recharging $ tmpLess name
               , OnSmash $ tmpLess name ]
  , idesc    = ""  -- no description needed; stats are enough
  , ikit     = []
  }

tmpEffects :: Text -> Dice -> [Effect] -> ItemKind
tmpEffects name icount effects =
  let tmp = tmpAspects name []
  in tmp { icount
         , ieffects = effects
                      ++ [ Recharging $ tmpNoLonger name
                         , OnSmash $ tmpNoLonger name ]
         }

tmpStrengthened = tmpAspects "strengthened" [AddSkill AbHurtMelee 20]
tmpWeakened = tmpAspects "weakened"
                         [AddSkill AbHurtMelee (-30)]  -- don't cancel out ^
tmpProtectedMelee = tmpAspects "protected from melee"
                               [AddSkill AbArmorMelee 50]
tmpProtectedRanged = tmpAspects "protected from ranged"
                                [AddSkill AbArmorRanged 25]
tmpVulnerable = tmpAspects "defenseless" [ AddSkill AbArmorMelee (-50)
                                         , AddSkill AbArmorRanged (-25) ]
tmpResolute = tmpAspects "resolute" [AddSkill AbMaxCalm 60]
tmpFast20 = tmpAspects "hasted" [AddSkill AbSpeed 20]
tmpSlow10 = tmpAspects "slowed" [AddSkill AbSpeed (-10)]
tmpFarSighted = tmpAspects "far-sighted" [AddSkill AbSight 5]
tmpBlind = tmpAspects "blind" [AddSkill AbSight (-99)]
tmpKeenSmelling = tmpAspects "keen-smelling" [AddSkill AbSmell 2]
tmpNoctovision = tmpAspects "shiny-eyed" [AddSkill AbNocto 2]
tmpDrunk = tmpAspects "drunk" [ AddSkill AbHurtMelee 30  -- fury
                              , AddSkill AbArmorMelee (-20)
                              , AddSkill AbArmorRanged (-20)
                              , AddSkill AbSight (-8)
                              ]

tmpRegenerating =
  tmpEffects "regenerating" (4 + 1 `d` 2) [Recharging (RefillHP 1)]
tmpPoisoned =
  tmpEffects "poisoned" (4 + 1 `d` 2) [Recharging (RefillHP (-1))]
tmpSlow10Resistant =
  tmpEffects "slow resistant" (8 + 1 `d` 4)
             [Recharging (DropItem 1 1 COrgan "slowed")]
tmpPoisonResistant =
  tmpEffects "poison resistant" (8 + 1 `d` 4)
             [Recharging (DropItem 1 maxBound COrgan "poisoned")]
