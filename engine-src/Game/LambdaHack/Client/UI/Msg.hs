{-# LANGUAGE DeriveGeneric, FlexibleInstances, GADTs,
             GeneralizedNewtypeDeriving, KindSignatures, StandaloneDeriving #-}
-- | Game messages displayed on top of the screen for the player to read
-- and then saved to player history.
module Game.LambdaHack.Client.UI.Msg
  ( -- * Msg
    MsgShowAndSave, MsgShow, MsgSave, MsgIgnore, MsgDifferent
  , MsgClass(..), MsgCreate, MsgSingle(..)
  , Msg(..), toMsg
  , interruptsRunning, disturbsResting
    -- * Report
  , Report, nullReport, consReport, addEolToNewReport
  , renderReport, anyInReport
    -- * History
  , History, newReport, emptyHistory, addToReport, archiveReport, lengthHistory
  , renderHistory
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , isSavedToHistory, isDisplayed, bindsPronouns, msgColor
  , UAttrString, RepMsgN, uToAttrString, attrLineToU
  , emptyReport, nullFilteredReport, snocReport
  , renderWholeReport, renderRepetition
  , scrapRepetition, renderTimeReport
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Data.Binary
import           Data.Kind (Type)
import           Data.Vector.Binary ()
import qualified Data.Vector.Unboxed as U
import           GHC.Generics (Generic)

import           Game.LambdaHack.Client.UI.Overlay
import qualified Game.LambdaHack.Common.RingBuffer as RB
import           Game.LambdaHack.Common.Time
import qualified Game.LambdaHack.Definition.Color as Color

-- * UAttrString

type UAttrString = U.Vector Word32

uToAttrString :: UAttrString -> AttrString
uToAttrString v = map Color.AttrCharW32 $ U.toList v

attrLineToU :: AttrString -> UAttrString
attrLineToU l = U.fromList $ map Color.attrCharW32 l

-- * Msg

-- | The type of a single game message.
data Msg = Msg
  { msgLine              :: AttrString
                            -- ^ the colours and characters of the message;
                            --   not just text, in case there was some colour
                            --   unrelated to msg class
  , msgIsSavedToHistory  :: Bool
  , msgIsDisplayed       :: Bool
  , msgInterruptsRunning :: Bool
  , msgDisturbsResting   :: Bool
  , msgBindsPronouns     :: Bool
  }
  deriving Generic

instance Binary Msg

toMsg :: MsgCreate a => Maybe [(String, Color.Color)] -> MsgClass a -> a -> Msg
toMsg mprefixList msgClass a =
  let (t, _) = msgCreateConvert a  -- TODO store both, instead of msgIsSavedToHistory and msgIsDisplayed
      matchPrefix msgClassString prefixList =
        find ((`isPrefixOf` msgClassString) . fst) prefixList
      findColorInConfig prefixList =
        fromMaybe Color.White (snd <$> matchPrefix (show msgClass) prefixList)
      color = maybe (msgColor msgClass) findColorInConfig mprefixList
      msgLine = textFgToAS color t
      msgIsSavedToHistory = isSavedToHistory msgClass
      msgIsDisplayed = isDisplayed msgClass
      msgInterruptsRunning = interruptsRunning msgClass
      msgDisturbsResting = disturbsResting msgClass
      msgBindsPronouns = bindsPronouns msgClass
  in Msg {..}

class MsgCreate a where
  msgCreateConvert :: a -> (Text, Text)

instance MsgCreate MsgShowAndSave where
  msgCreateConvert t = (t, t)

instance MsgCreate MsgShow where
  msgCreateConvert (t, ()) = (t, "")

instance MsgCreate MsgSave where
  msgCreateConvert ((), t) = ("", t)

instance MsgCreate MsgIgnore where
  msgCreateConvert () = ("", "")

instance MsgCreate MsgDifferent where
  msgCreateConvert tt = tt

class MsgCreate a => MsgSingle a where
  msgSameInject :: Text -> a

instance MsgSingle MsgShowAndSave where
  msgSameInject t = t

instance MsgSingle MsgShow where
  msgSameInject t = (t, ())

instance MsgSingle MsgSave where
  msgSameInject t = ((), t)

instance MsgSingle MsgIgnore where
  msgSameInject _ = ()

type MsgShowAndSave = Text

type MsgShow = (Text, ())

type MsgSave = ((), Text)

type MsgIgnore = ()

type MsgDifferent = (Text, Text)

data MsgClass :: Type -> Type where
  MsgAdmin :: MsgClass MsgShowAndSave
  MsgBecomeSleep :: MsgClass MsgShowAndSave
  MsgBecomeBeneficialUs :: MsgClass MsgShowAndSave
  MsgBecomeHarmfulUs :: MsgClass MsgShowAndSave
  MsgBecome :: MsgClass MsgShowAndSave
  MsgNoLongerSleep :: MsgClass MsgShowAndSave
  MsgNoLongerUs :: MsgClass MsgShowAndSave
  MsgNoLonger :: MsgClass MsgShowAndSave
  MsgLongerUs :: MsgClass MsgShowAndSave
  MsgLonger :: MsgClass MsgShowAndSave
  MsgItemCreation :: MsgClass MsgShowAndSave
  MsgItemDestruction :: MsgClass MsgShowAndSave
  MsgDeathGood :: MsgClass MsgShowAndSave
  MsgDeathBad :: MsgClass MsgShowAndSave
  MsgDeathBoring :: MsgClass MsgShowAndSave
  MsgNearDeath :: MsgClass MsgShowAndSave
  MsgLeader :: MsgClass MsgShowAndSave
  MsgDiplomacy :: MsgClass MsgShowAndSave
  MsgOutcome :: MsgClass MsgShowAndSave
  MsgPlot :: MsgClass MsgShowAndSave
  MsgLandscape :: MsgClass MsgShowAndSave
  MsgDiscoTile :: MsgClass MsgShowAndSave
  MsgItemDisco :: MsgClass MsgShowAndSave
  MsgSpotActor :: MsgClass MsgShowAndSave
  MsgSpotThreat :: MsgClass MsgShowAndSave
  MsgItemMove :: MsgClass MsgShowAndSave
  MsgItemMoveDifferent :: MsgClass MsgDifferent
  MsgItemMoveLog :: MsgClass MsgSave  -- TODO: remove
  MsgAction :: MsgClass MsgShowAndSave
  MsgActionMinor :: MsgClass MsgShowAndSave
  MsgEffectMajor :: MsgClass MsgShowAndSave
  MsgEffect :: MsgClass MsgShowAndSave
  MsgEffectMinor :: MsgClass MsgShowAndSave
  MsgMisc :: MsgClass MsgShowAndSave
  MsgHeardElsewhere :: MsgClass MsgShowAndSave
  MsgHeardClose :: MsgClass MsgShowAndSave
  MsgHeard :: MsgClass MsgShowAndSave
  MsgFocus :: MsgClass MsgShowAndSave
  MsgWarning :: MsgClass MsgShowAndSave
  MsgRangedPowerfulWe :: MsgClass MsgShowAndSave
  MsgRangedPowerfulUs :: MsgClass MsgShowAndSave
  MsgRanged :: MsgClass MsgShowAndSave  -- not ours or projectiles are hit
  MsgRangedUs :: MsgClass MsgShowAndSave
  MsgNeutralEvent :: MsgClass MsgShowAndSave
  MsgNeutralEventRare :: MsgClass MsgShowAndSave
  MsgMeleePowerfulWe :: MsgClass MsgShowAndSave
  MsgMeleePowerfulUs :: MsgClass MsgShowAndSave
  MsgMeleeInterestingWe :: MsgClass MsgShowAndSave
  MsgMeleeInterestingUs :: MsgClass MsgShowAndSave
  MsgMelee :: MsgClass MsgShowAndSave  -- not ours or projectiles are hit
  MsgMeleeUs :: MsgClass MsgShowAndSave
  MsgDone :: MsgClass MsgShowAndSave
  MsgAtFeetMajor :: MsgClass MsgShowAndSave
  MsgAtFeet :: MsgClass MsgShowAndSave
  MsgNumeric :: MsgClass MsgSave
  MsgSpam :: MsgClass MsgIgnore
  MsgMacro :: MsgClass MsgIgnore
  MsgRunStop :: MsgClass MsgShow
  MsgPrompt :: MsgClass MsgShow
  MsgPromptFocus :: MsgClass MsgShow
  MsgPromptMention :: MsgClass MsgShow
  MsgPromptWarning :: MsgClass MsgShow
  MsgPromptThreat :: MsgClass MsgShow
  MsgPromptItem :: MsgClass MsgShow
  MsgAlert :: MsgClass MsgShow
  MsgStopPlayback :: MsgClass MsgIgnore

deriving instance Show (MsgClass a)

isSavedToHistory :: MsgClass a -> Bool
isSavedToHistory MsgItemMoveDifferent = False
isSavedToHistory MsgSpam = False
isSavedToHistory MsgMacro = False
isSavedToHistory MsgRunStop = False
isSavedToHistory MsgPrompt = False
isSavedToHistory MsgPromptFocus = False
isSavedToHistory MsgPromptMention = False
isSavedToHistory MsgPromptWarning = False
isSavedToHistory MsgPromptThreat = False
isSavedToHistory MsgPromptItem = False
isSavedToHistory MsgAlert = False
isSavedToHistory MsgStopPlayback = False
isSavedToHistory _ = True

isDisplayed :: MsgClass a -> Bool
isDisplayed MsgItemMoveLog = False
isDisplayed MsgNumeric = False
isDisplayed MsgRunStop = False
isDisplayed MsgSpam = False
isDisplayed MsgMacro = False
isDisplayed MsgStopPlayback = False
isDisplayed _ = True

interruptsRunning :: MsgClass a -> Bool
interruptsRunning MsgAdmin = False
interruptsRunning MsgBecome = False
interruptsRunning MsgNoLonger = False
interruptsRunning MsgLonger = False
interruptsRunning MsgItemDisco = False
interruptsRunning MsgItemMove = False
interruptsRunning MsgItemMoveDifferent = False
interruptsRunning MsgItemMoveLog = False
interruptsRunning MsgActionMinor = False
interruptsRunning MsgEffectMinor = False
interruptsRunning MsgHeard = False
  -- MsgHeardClose interrupts, even if running started while hearing close
interruptsRunning MsgRanged = False
interruptsRunning MsgAtFeet = False
interruptsRunning MsgNumeric = False
interruptsRunning MsgSpam = False
interruptsRunning MsgMacro = False
interruptsRunning MsgRunStop = False
interruptsRunning MsgPrompt = False
interruptsRunning MsgPromptFocus = False
interruptsRunning MsgPromptMention = False
interruptsRunning MsgPromptWarning = False
interruptsRunning MsgPromptThreat = False
interruptsRunning MsgPromptItem = False
  -- MsgAlert means something went wrong, so alarm
interruptsRunning _ = True

disturbsResting :: MsgClass a -> Bool
disturbsResting MsgAdmin = False
disturbsResting MsgBecome = False
disturbsResting MsgNoLonger = False
disturbsResting MsgLonger = False
disturbsResting MsgLeader = False -- handled separately
disturbsResting MsgItemDisco = False
disturbsResting MsgItemMove = False
disturbsResting MsgItemMoveDifferent = False
disturbsResting MsgItemMoveLog = False
disturbsResting MsgActionMinor = False
disturbsResting MsgEffectMinor = False
disturbsResting MsgHeardElsewhere = False
disturbsResting MsgHeardClose = False -- handled separately
disturbsResting MsgHeard = False
disturbsResting MsgRanged = False
disturbsResting MsgAtFeet = False
disturbsResting MsgNumeric = False
disturbsResting MsgSpam = False
disturbsResting MsgMacro = False
disturbsResting MsgRunStop = False
disturbsResting MsgPrompt = False
disturbsResting MsgPromptFocus = False
disturbsResting MsgPromptMention = False
disturbsResting MsgPromptWarning = False
disturbsResting MsgPromptThreat = False
disturbsResting MsgPromptItem = False
  -- MsgAlert means something went wrong, so alarm
disturbsResting _ = True

-- Only player's non-projectile actors getting hit introduce subjects,
-- because only such hits are guaranteed to be perceived.
-- Here we also mark friends being hit, but that's a safe approximation.
-- We also mark the messages that use the introduced subjects
-- by referring to them via pronouns. They can't be moved freely either.
bindsPronouns :: MsgClass a -> Bool
bindsPronouns MsgLongerUs = True
bindsPronouns MsgRangedPowerfulUs = True
bindsPronouns MsgRangedUs = True
bindsPronouns MsgMeleePowerfulUs = True
bindsPronouns MsgMeleeInterestingUs = True
bindsPronouns MsgMeleeUs = True
bindsPronouns _ = False

-- Only initially @White@ colour in text (e.g., not highlighted @BrWhite@)
-- gets replaced by the one indicated.
--
-- See the discussion of colours and the table of colours at
-- https://github.com/LambdaHack/LambdaHack/wiki/Display#colours
-- Another mention of colours, concerning terrain, is in PLAYING.md manual.
-- The manual and this code should follow the wiki.
cVeryBadEvent, cBadEvent, cRisk, cGraveRisk, cVeryGoodEvent, cGoodEvent, cVista, cSleep, cWakeUp, cGreed, cNeutralEvent, cRareNeutralEvent, cIdentification, cMeta, cBoring, cGameOver :: Color.Color
cVeryBadEvent = Color.Red
cBadEvent = Color.BrRed
cRisk = Color.Magenta
cGraveRisk = Color.BrMagenta
cVeryGoodEvent = Color.Green
cGoodEvent = Color.BrGreen
cVista = Color.BrGreen
cSleep = Color.Blue
cWakeUp = Color.BrBlue
cGreed = Color.BrBlue
cNeutralEvent = Color.Cyan
cRareNeutralEvent = Color.BrCyan
cIdentification = Color.Brown
cMeta = Color.BrYellow
cBoring = Color.White
cGameOver = Color.BrWhite

msgColor :: MsgClass a -> Color.Color
msgColor MsgAdmin = cBoring
msgColor MsgBecomeSleep = cSleep
msgColor MsgBecomeBeneficialUs = cGoodEvent
msgColor MsgBecomeHarmfulUs = cBadEvent
msgColor MsgBecome = cBoring
msgColor MsgNoLongerSleep = cWakeUp
msgColor MsgNoLongerUs = cBoring
msgColor MsgNoLonger = cBoring
msgColor MsgLongerUs = cBoring  -- not important enough
msgColor MsgLonger = cBoring  -- not important enough, no disturb even
msgColor MsgItemCreation = cGreed
msgColor MsgItemDestruction = cBoring  -- common, colourful components created
msgColor MsgDeathGood = cVeryGoodEvent
msgColor MsgDeathBad = cVeryBadEvent
msgColor MsgDeathBoring = cBoring
msgColor MsgNearDeath = cGraveRisk
msgColor MsgLeader = cBoring
msgColor MsgDiplomacy = cMeta  -- good or bad
msgColor MsgOutcome = cGameOver
msgColor MsgPlot = cBoring
msgColor MsgLandscape = cBoring
msgColor MsgDiscoTile = cIdentification
msgColor MsgItemDisco = cIdentification
msgColor MsgSpotActor = cBoring  -- too common; warning in @MsgSpotThreat@
msgColor MsgSpotThreat = cGraveRisk
msgColor MsgItemMove = cBoring
msgColor MsgItemMoveDifferent = cBoring
msgColor MsgItemMoveLog = cBoring
msgColor MsgAction = cBoring
msgColor MsgActionMinor = cBoring
msgColor MsgEffectMajor = cRareNeutralEvent
msgColor MsgEffect = cNeutralEvent
msgColor MsgEffectMinor = cBoring
msgColor MsgMisc = cBoring
msgColor MsgHeardElsewhere = cBoring
msgColor MsgHeardClose = cGraveRisk
msgColor MsgHeard = cRisk
msgColor MsgFocus = cVista
msgColor MsgWarning = cMeta
msgColor MsgRangedPowerfulWe = cGoodEvent
msgColor MsgRangedPowerfulUs = cBadEvent
msgColor MsgRanged = cBoring
msgColor MsgRangedUs = cRisk
msgColor MsgNeutralEvent = cNeutralEvent
msgColor MsgNeutralEventRare = cRareNeutralEvent
msgColor MsgMeleePowerfulWe = cGoodEvent
msgColor MsgMeleePowerfulUs = cBadEvent
msgColor MsgMeleeInterestingWe = cGoodEvent
msgColor MsgMeleeInterestingUs = cBadEvent
msgColor MsgMelee = cBoring
msgColor MsgMeleeUs = cRisk
msgColor MsgDone = cBoring
msgColor MsgAtFeetMajor = cBoring
msgColor MsgAtFeet = cBoring
msgColor MsgNumeric = cBoring
msgColor MsgSpam = cBoring
msgColor MsgMacro = cBoring
msgColor MsgRunStop = cBoring
msgColor MsgPrompt = cBoring
msgColor MsgPromptFocus = cVista
msgColor MsgPromptMention = cNeutralEvent
msgColor MsgPromptWarning = cMeta
msgColor MsgPromptThreat = cRisk
msgColor MsgPromptItem = cGreed
msgColor MsgAlert = cMeta
msgColor MsgStopPlayback = cMeta

-- * Report

data RepMsgN = RepMsgN {repMsg :: Msg, _repN :: Int}
  deriving Generic

instance Binary RepMsgN

-- | The set of messages, with repetitions, to show at the screen at once.
newtype Report = Report [RepMsgN]
  deriving Binary

-- | Empty set of messages.
emptyReport :: Report
emptyReport = Report []

-- | Test if the set of messages is empty.
nullReport :: Report -> Bool
nullReport (Report l) = null l

nullFilteredReport :: Report -> Bool
nullFilteredReport (Report l) =
  null $ filter (\(RepMsgN msg n) -> n > 0
                                     && (msgIsSavedToHistory msg
                                         || msgIsDisplayed msg)) l

-- | Add a message to the end of the report.
snocReport :: Report -> Msg -> Int -> Report
snocReport (Report !r) y n =
  if null $ msgLine y then Report r else Report $ RepMsgN y n : r

-- | Add a message to the start of report.
consReport :: Msg -> Report -> Report
consReport Msg{msgLine=[]} rep = rep
consReport y (Report r) = Report $ r ++ [RepMsgN y 1]

-- | Render a report as a (possibly very long) 'AttrString'. Filter out
-- messages not meant for display, unless not displaying, but recalling.
renderReport :: Bool -> Report -> AttrString
renderReport displaying (Report r) =
  let rep = Report $ if displaying
                     then filter (msgIsDisplayed . repMsg) r
                     else r
  in renderWholeReport rep

-- | Render a report as a (possibly very long) 'AttrString'.
renderWholeReport :: Report -> AttrString
renderWholeReport (Report []) = []
renderWholeReport (Report (x : xs)) =
  renderWholeReport (Report xs) <+:> renderRepetition x

renderRepetition :: RepMsgN -> AttrString
renderRepetition (RepMsgN s 0) = msgLine s
renderRepetition (RepMsgN s 1) = msgLine s
renderRepetition (RepMsgN s n) = msgLine s ++ stringToAS ("<x" ++ show n ++ ">")

anyInReport :: (Msg -> Bool) -> Report -> Bool
anyInReport f (Report xns) = any (f . repMsg) xns

-- * History

-- | The history of reports. This is a ring buffer of the given length
-- containing old archived history and two most recent reports stored
-- separately.
data History = History
  { newReport       :: Report
  , newTime         :: Time
  , oldReport       :: Report
  , oldTime         :: Time
  , archivedHistory :: RB.RingBuffer UAttrString }
  deriving Generic

instance Binary History

-- | Empty history of the given maximal length.
emptyHistory :: Int -> History
emptyHistory size =
  let ringBufferSize = size - 1  -- a report resides outside the buffer
  in History emptyReport timeZero emptyReport timeZero
             (RB.empty ringBufferSize U.empty)

scrapRepetition :: History -> Maybe History
scrapRepetition History{ newReport = Report newMsgs
                       , oldReport = Report oldMsgs
                       , .. } =
  case newMsgs of
    -- We take into account only first message of the new report,
    -- because others were deduplicated as they were added.
    -- We keep the message in the new report, because it should not
    -- vanish from the screen. In this way the message may be passed
    -- along many reports.
    RepMsgN s1 n1 : rest1 ->
      let commutative s = not $ msgBindsPronouns s
          butLastEOL [] = []
          butLastEOL s = if last s == Color.attrChar1ToW32 '\n'
                         then init s
                         else s
          f (RepMsgN s2 _) = butLastEOL (msgLine s1) == butLastEOL (msgLine s2)
--                             && msgClass s1 == msgClass s2
--                                  -- the class may not display or not save
      in case break f rest1 of
        (_, []) | commutative s1 -> case break f oldMsgs of
          (noDup, RepMsgN s2 n2 : rest2) ->
            -- We keep the occurence of the message in the new report only.
            let newReport = Report $ RepMsgN s2 (n1 + n2) : rest1
                oldReport = Report $ noDup ++ rest2
            in Just History{..}
          _ -> Nothing
        (noDup, RepMsgN s2 n2 : rest2) | commutative s1
                                         || all (commutative . repMsg) noDup ->
          -- We keep the older (and so, oldest) occurence of the message,
          -- to avoid visual disruption by moving the message around.
          let newReport = Report $ noDup ++ RepMsgN s2 (n1 + n2) : rest2
              oldReport = Report oldMsgs
          in Just History{..}
        _ -> Nothing
    _ -> Nothing  -- empty new report

-- | Add a message to the new report of history, eliminating a possible
-- duplicate and noting its existence in the result.
addToReport :: History -> Msg -> Int -> Time -> (History, Bool)
addToReport History{..} msg n time =
  let newH = History{newReport = snocReport newReport msg n, newTime = time, ..}
  in case scrapRepetition newH of
    Just scrappedH -> (scrappedH, True)
    Nothing -> (newH, False)

-- | Add a newline to end of the new report of history, unless empty.
addEolToNewReport :: History -> History
addEolToNewReport hist =
  if nullFilteredReport $ newReport hist
  then hist
  else let addEolToReport (Report []) = error "addEolToReport: empty report"
           addEolToReport (Report (hd : tl)) = Report $ addEolToRepMsgN hd : tl
           addEolToRepMsgN rm = rm {repMsg = addEolToMsg $ repMsg rm}
           addEolToMsg msg = msg {msgLine = msgLine msg ++ stringToAS "\n"}
       in hist {newReport = addEolToReport $ newReport hist}

-- | Archive old report to history, filtering out messages with 0 duplicates
-- and prompts. Set up new report with a new timestamp.
archiveReport :: History -> History
archiveReport History{newReport=Report newMsgs, ..} =
  let f (RepMsgN _ n) = n > 0
      newReportNon0 = Report $ filter f newMsgs
  in if nullReport newReportNon0
     then -- Drop empty new report.
          History emptyReport timeZero oldReport oldTime archivedHistory
     else let lU = map attrLineToU $ renderTimeReport oldTime oldReport
          in History emptyReport timeZero newReportNon0 newTime
             $ foldl' (\ !h !v -> RB.cons v h) archivedHistory (reverse lU)

renderTimeReport :: Time -> Report -> [AttrString]
renderTimeReport !t (Report r) =
  let turns = t `timeFitUp` timeTurn
      rep = Report $ filter (msgIsSavedToHistory . repMsg) r
  in [ stringToAS (show turns ++ ": ") ++ renderReport False rep
     | not $ nullReport rep ]

lengthHistory :: History -> Int
lengthHistory History{oldReport, archivedHistory} =
  RB.length archivedHistory
  + length (renderTimeReport timeZero oldReport)
      -- matches @renderHistory@

-- | Render history as many lines of text. New report is not rendered.
-- It's expected to be empty when history is shown.
renderHistory :: History -> [AttrString]
renderHistory History{..} = renderTimeReport oldTime oldReport
                            ++ map uToAttrString (RB.toList archivedHistory)
