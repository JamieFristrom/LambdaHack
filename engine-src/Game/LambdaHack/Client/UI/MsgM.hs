-- | Monadic operations on game messages.
module Game.LambdaHack.Client.UI.MsgM
  ( msgAddDuplicate, msgAdd, msgLnAdd, msgAdd0, msgLnAdd0, promptAdd, promptAdd0
  , promptMainKeys, recordHistory
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import qualified Data.EnumMap.Strict as EM

import           Game.LambdaHack.Client.MonadClient
import           Game.LambdaHack.Client.State
import           Game.LambdaHack.Client.UI.EffectDescription
import qualified Game.LambdaHack.Client.UI.HumanCmd as HumanCmd
import qualified Game.LambdaHack.Client.UI.Key as K
import           Game.LambdaHack.Client.UI.MonadClientUI
import           Game.LambdaHack.Client.UI.Msg
import           Game.LambdaHack.Client.UI.SessionUI
import           Game.LambdaHack.Client.UI.UIOptions
import           Game.LambdaHack.Common.ActorState
import           Game.LambdaHack.Common.MonadStateRead
import           Game.LambdaHack.Common.State
import           Game.LambdaHack.Definition.Defs

-- | Add a message to the current report.
msgAddDuplicate :: MonadClientUI m => Text -> MsgClass -> Int -> m Bool
msgAddDuplicate msg msgClass n = do
  sUIOptions <- getsSession sUIOptions
  time <- getsState stime
  history <- getsSession shistory
  let mem = EM.fromList <$> uMessageColors sUIOptions
      (nhistory, duplicate) =
        addToReport history (toMsg mem msgClass msg) n time
  modifySession $ \sess -> sess {shistory = nhistory}
  return duplicate

-- | Add a message to the current report. Do not report if it was a duplicate.
msgAdd :: MonadClientUI m => MsgClass -> Text -> m ()
msgAdd msgClass msg = void $ msgAddDuplicate msg msgClass 1

-- | Add a message to the current report. End previously collected report,
-- if any, with newline.
msgLnAdd :: MonadClientUI m => MsgClass -> Text -> m ()
msgLnAdd msgClass msg = do
  modifySession $ \sess -> sess {shistory = addEolToNewReport $ shistory sess}
  msgAdd msgClass msg

-- | Add a message to the current report with 0 copies for the purpose
-- of collating duplicates. Do not report if it was a duplicate.
msgAdd0 :: MonadClientUI m => MsgClass -> Text -> m ()
msgAdd0 msgClass msg = void $ msgAddDuplicate msg msgClass 0

-- | Add a message to the current report with 0 copies for the purpose
-- of collating duplicates. Do not report if it was a duplicate.
-- End previously collected report, if any, with newline.
msgLnAdd0 :: MonadClientUI m => MsgClass -> Text -> m ()
msgLnAdd0 msgClass msg = do
  modifySession $ \sess -> sess {shistory = addEolToNewReport $ shistory sess}
  msgAdd0 msgClass msg

-- | Add a prompt to the current report. Do not report if it was a duplicate.
promptAdd :: MonadClientUI m => Text -> m ()
promptAdd = msgAdd MsgAlert

-- | Add a prompt to the current report with 0 copies for the purpose
-- of collating duplicates. Do not report if it was a duplicate.
promptAdd0 :: MonadClientUI m => Text -> m ()
promptAdd0 = msgAdd0 MsgPrompt

-- | Add a prompt with basic keys description.
promptMainKeys :: MonadClientUI m => m ()
promptMainKeys = do
  side <- getsClient sside
  ours <- getsState $ fidActorNotProjGlobalAssocs side
  revCmd <- revCmdMap
  let kmHelp = revCmd HumanCmd.Hint
      kmViewStash = revCmd (HumanCmd.ChooseItemMenu (MStore CStash))
      kmItemStash = revCmd (HumanCmd.MoveItem [CGround, CEqp] CStash
                                              Nothing False)
      kmXhairPointerFloor = revCmd HumanCmd.XhairPointerFloor
  saimMode <- getsSession saimMode
  UIOptions{uVi, uLeftHand} <- getsSession sUIOptions
  xhair <- getsSession sxhair
  -- The silly "axwdqezc" name of keys is chosen to match "hjklyubn",
  -- which the usual way of writing them.
  let moveKeys | uVi && uLeftHand = "keypad or axwdqezc or hjklyubn"
               | uLeftHand = "keypad or axwdqezc"
               | uVi = "keypad or hjklyubn"
               | otherwise = "keypad"
      manyTeammates = length ours > 1
      detailAtDefault = (detailLevel <$> saimMode) == Just defaultDetailLevel
      keepTab = if manyTeammates
                then "Switch to another teammate with Tab, while all others auto-melee foes, if adjacent, but normally don't chase them."
                else ""
      describePos = if describeIsNormal
                    then "Describe map position with MMB or RMB."
                    else ""
      viewEquip = if stashKeysAreNormal
                  then "View shared 'I'nventory stash and stash items into the 'i'nventory."
                  else ""
      moreHelp = "Press '" <> tshow kmHelp <> "' for more help."
      describeIsNormal = kmXhairPointerFloor == K.middleButtonReleaseKM
      stashKeysAreNormal = kmViewStash == K.mkChar 'I'
                           && kmItemStash == K.mkChar 'i'
      keys | isNothing saimMode =
        "Explore with" <+> moveKeys <+> "or mouse."
        <+> describePos
        <+> viewEquip
        <+> keepTab
        <+> moreHelp
           | otherwise =
        (if detailAtDefault then "" else miniHintAiming)
        <+> tgtKindVerb xhair
        <+> "with" <+> moveKeys <+> "keys or mouse."
        <+> keepTab
        <+> moreHelp
  void $ promptAdd0 keys

tgtKindVerb :: Maybe Target -> Text
tgtKindVerb mtgt = case mtgt of
  Just TEnemy{} -> "Aim at enemy"
  Just TNonEnemy{} -> "Aim at non-enemy"
  Just TPoint{} -> "Aim at position"
  Just TVector{} -> "Indicate a move vector"
  Nothing -> "Start aiming"

-- | Store new report in the history and archive old report.
recordHistory :: MonadClientUI m => m ()
recordHistory =
  modifySession $ \sess -> sess {shistory = archiveReport $ shistory sess}
