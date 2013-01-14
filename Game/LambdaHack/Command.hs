{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
-- | Abstract syntax of server and client commands.
module Game.LambdaHack.Command
  ( CmdCli(..), CmdUpdateCli(..), CmdQueryCli(..)
  , CmdSer(..), Cmd(..)
  , majorCmd, minorCmd, noRemoteCmd, cmdDescription
  ) where

import qualified Data.IntSet as IS
import Data.Text (Text)
import Data.Typeable
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Actor
import Game.LambdaHack.Animation (Frames)
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.State
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Vector
import Game.LambdaHack.VectorXY

-- | Abstract syntax of client commands.
data CmdCli =
    CmdUpdateCli CmdUpdateCli
  | CmdQueryCli CmdQueryCli
  deriving Show

data CmdUpdateCli =
    PickupCli ActorId Item Item
  | ApplyCli ActorId MU.Part Item
  | ShowMsgCli Msg
  | ShowItemsCli Discoveries Msg [Item]
  | AnimateDeathCli ActorId
  | InvalidateArenaCli LevelId
  | DiscoverCli (Kind.Id ItemKind) Item
  | RememberCli LevelId IS.IntSet Level  -- TODO: Level is an overkill
  | RememberPerCli LevelId Perception Level FactionDict
  | SwitchLevelCli ActorId LevelId Actor [Item]
  | EffectCli Msg (Point, Point) Int Bool
  | ProjectCli Point ActorId Item
  | ShowAttackCli ActorId ActorId MU.Part Item Bool
  | AnimateBlockCli ActorId ActorId MU.Part
  | DisplaceCli ActorId ActorId
  | DisplayPushCli
  | DisplayFramesPushCli Frames
  | MoreFullCli Msg
  | MoreBWCli Msg
  | RestartCli StateClient State
  deriving Show

data CmdQueryCli =
    ShowSlidesCli Slideshow
  | CarryOnCli
  | ConfirmShowItemsCli Discoveries Msg [Item]
  | SelectLeaderCli ActorId LevelId
  | ConfirmYesNoCli Msg
  | ConfirmMoreBWCli Msg
  | ConfirmMoreFullCli Msg
  | NullReportCli
  | SetArenaLeaderCli LevelId ActorId
  | GameSaveCli
  | HandlePlayerCli ActorId
  deriving Show

-- | Abstract syntax of server commands.
data CmdSer =
    ApplySer ActorId MU.Part Item
  | ProjectSer ActorId Point MU.Part Item
  | TriggerSer ActorId Point
  | PickupSer ActorId Item Char
  | DropSer ActorId Item
  | WaitSer ActorId
  | MoveSer ActorId Vector
  | RunSer ActorId Vector
  | GameExitSer
  | GameRestartSer
  | GameSaveSer
  | CfgDumpSer
  deriving (Show, Typeable)

-- | Abstract syntax of player commands.
data Cmd =
    -- These usually take time.
    Apply       { verb :: MU.Part, object :: MU.Part, syms :: [Char] }
  | Project     { verb :: MU.Part, object :: MU.Part, syms :: [Char] }
  | TriggerDir  { verb :: MU.Part, object :: MU.Part, feature :: F.Feature }
  | TriggerTile { verb :: MU.Part, object :: MU.Part, feature :: F.Feature }
  | Pickup
  | Drop
  | Wait
  | Move VectorXY
  | Run VectorXY
    -- These do not take time.
  | GameExit
  | GameRestart
  | GameSave
  | CfgDump
  | Inventory
  | TgtFloor
  | TgtEnemy
  | TgtAscend Int
  | EpsIncr Bool
  | Cancel
  | Accept
  | Clear
  | History
  | HeroCycle
  | HeroBack
  | Help
  | SelectHero Int
  | DebugArea
  | DebugOmni
  | DebugSmell
  | DebugVision
  deriving (Show, Read, Eq, Ord)

-- | Major commands land on the first page of command help.
majorCmd :: Cmd -> Bool
majorCmd cmd = case cmd of
  Apply{}       -> True
  Project{}     -> True
  TriggerDir{}  -> True
  TriggerTile{} -> True
  Pickup        -> True
  Drop          -> True
  GameExit      -> True
  GameRestart   -> True
  GameSave      -> True
  Inventory     -> True
  Help          -> True
  _             -> False

-- | Minor commands land on the second page of command help.
minorCmd :: Cmd -> Bool
minorCmd cmd = case cmd of
  TgtFloor    -> True
  TgtEnemy    -> True
  TgtAscend{} -> True
  EpsIncr{}   -> True
  Cancel      -> True
  Accept      -> True
  Clear       -> True
  History     -> True
  CfgDump     -> True
  HeroCycle   -> True
  HeroBack    -> True
  _           -> False

-- | Commands that are forbidden on a remote level, because they
-- would usually take time when invoked on one.
-- Not that movement commands are not included, because they take time
-- on normal levels, but don't take time on remote levels, that is,
-- in targeting mode.
noRemoteCmd :: Cmd -> Bool
noRemoteCmd cmd = case cmd of
  Apply{}       -> True
  Project{}     -> True
  TriggerDir{}  -> True
  TriggerTile{} -> True
  Pickup        -> True
  Drop          -> True
  Wait          -> True
  _             -> False

-- | Description of player commands.
cmdDescription :: Cmd -> Text
cmdDescription cmd = case cmd of
  Apply{..}       -> makePhrase [verb, MU.AW object]
  Project{..}     -> makePhrase [verb, MU.AW object]
  TriggerDir{..}  -> makePhrase [verb, MU.AW object]
  TriggerTile{..} -> makePhrase [verb, MU.AW object]
  Pickup      -> "get an object"
  Drop        -> "drop an object"
  Move{}      -> "move"
  Run{}       -> "run"
  Wait        -> "wait"

  GameExit    -> "save and exit"
  GameRestart -> "restart game"
  GameSave    -> "save game"
  CfgDump     -> "dump current configuration"
  Inventory   -> "display inventory"
  TgtFloor    -> "target position"
  TgtEnemy    -> "target monster"
  TgtAscend k | k == 1  -> "target next shallower level"
  TgtAscend k | k >= 2  -> "target" <+> showT k    <+> "levels shallower"
  TgtAscend k | k == -1 -> "target next deeper level"
  TgtAscend k | k <= -2 -> "target" <+> showT (-k) <+> "levels deeper"
  TgtAscend _ ->
    assert `failure` ("void level change in targeting in config file" :: Text)
  EpsIncr True  -> "swerve targeting line"
  EpsIncr False -> "unswerve targeting line"
  Cancel    -> "cancel action"
  Accept    -> "accept choice"
  Clear     -> "clear messages"
  History   -> "display previous messages"
  HeroCycle -> "cycle among heroes on level"
  HeroBack  -> "cycle among heroes in the dungeon"
  Help      -> "display help"
  SelectHero{} -> "select hero"
  DebugArea    -> "debug visible area"
  DebugOmni    -> "debug omniscience"
  DebugSmell   -> "debug smell"
  DebugVision  -> "debug vision modes"
