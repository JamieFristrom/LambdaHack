{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | Game action monads and basic building blocks for player and monster
-- actions. Has no access to the the main action type @Action@.
-- Does not export the @liftIO@ operation nor a few other implementation
-- details.
module Game.LambdaHack.Server.Action
  ( -- * Action monads
    MonadServerRO( getServer, getsServer )
  , MonadServer( putServer, modifyServer )
  , MonadServerChan
  , executorSer
    -- * Accessor to the Perception Reader
  , askPerceptionSer
    -- * Turn init operations
  , withPerception, remember
    -- * Assorted primitives
  , saveGameBkp, dumpCfg, endOrLoop, startFrontend
  , switchGlobalSelectedSide
  , sendUpdateCli, sendQueryCli, sendAIQueryCli
  , broadcastCli, broadcastPosCli
  , addHero
  ) where

import Control.Concurrent
import Control.Exception (finally)
import Control.Monad
import Control.Monad.Reader.Class
import qualified Control.Monad.State as St
import qualified Data.Char as Char
import Data.Dynamic
import qualified Data.IntMap as IM
import qualified Data.IntSet as IS
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified System.Random as R
import System.Time

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import qualified Game.LambdaHack.Client.Action.ConfigIO as Client.ConfigIO
import Game.LambdaHack.Client.Action.Frontend
import Game.LambdaHack.Client.Binding
import Game.LambdaHack.Client.Config
import Game.LambdaHack.Client.State
import Game.LambdaHack.CmdCli
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Faction
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.Server.Action.ActionClass (MonadServerRO(..), MonadServer(..), MonadServerChan(..), ConnDict)
import Game.LambdaHack.Server.Action.ActionType (executorSer)
import qualified Game.LambdaHack.Server.Action.ConfigIO as ConfigIO
import Game.LambdaHack.Server.Action.HighScore (register)
import qualified Game.LambdaHack.Server.Action.Save as Save
import Game.LambdaHack.Server.Config
import qualified Game.LambdaHack.Server.DungeonGen as DungeonGen
import Game.LambdaHack.Server.State
import Game.LambdaHack.State
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Utils.Assert

-- | Update the cached perception for the selected level, for all factions,
-- for the given computation. The assumption is the level, and only the level,
-- has changed since the previous perception calculation.
withPerception :: MonadServerRO m => m () -> m ()
withPerception m = do
  cops <- getsState scops
  configFovMode <- getsServer (configFovMode . sconfig)
  sdebugSer <- getsServer sdebugSer
  lvl <- getsState getArena
  arena <- getsState sarena
  let tryFov = stryFov sdebugSer
      fovMode = fromMaybe configFovMode tryFov
      per side = levelPerception cops fovMode side lvl
  local (IM.mapWithKey (\side lp -> M.insert arena (per side) lp)) m

-- | Get the current perception of the server.
askPerceptionSer :: MonadServerRO m => m Perception
askPerceptionSer = do
  lid <- getsState sarena
  pers <- ask
  side <- getsState sside
  return $! pers IM.! side M.! lid

-- | Update all factions memory of the current level.
--
-- This has to be strict wrt map operation sor we leak one perception
-- per turn. This has to lazy wrt the perception sets or we compute them
-- for factions that do not move, perceive or not even reside on the level.
-- When clients and server communicate via network the communication
-- has to be explicitely lazy and multiple updates have to collapsed
-- when sending is forced by the server asking a client to perceive
-- something or to act.
remember :: MonadServerChan m => m ()
remember = do
  arena <- getsState sarena
  lvl <- getsState getArena
  faction <- getsState sfaction
  pers <- ask
  funBroadcastCli (\fid ->
    RememberPerCli arena (pers IM.! fid M.! arena) lvl faction)
  funAIBroadcastCli (\fid ->
    RememberPerCli arena (pers IM.! fid M.! arena) lvl faction)

-- | Save the history and a backup of the save game file, in case of crashes.
--
-- See 'Save.saveGameBkp'.
saveGameBkp :: MonadServerChan m => m ()
saveGameBkp = do
  glo <- getState
  ser <- getServer
  faction <- getsState sfaction
  let queryCliLoc fid = sendQueryCli fid undefined -- GameSaveCli  -- TODO: do in parallel
  -- TODO: also save the targets from AI clients
  d <- mapM queryCliLoc $ IM.keys faction
--  configUI <- askConfigUI
  config <- getsServer sconfig
  liftIO $ Save.saveGameBkp config glo ser (IM.fromDistinctAscList $ zip (IM.keys faction) d)

-- | Dumps the current game rules configuration to a file.
dumpCfg :: MonadServer m => FilePath -> m ()
dumpCfg fn = do
  config <- getsServer sconfig
  liftIO $ ConfigIO.dump config fn

-- | Handle current score and display it with the high scores.
-- Aborts if display of the scores was interrupted by the user.
--
-- Warning: scores are shown during the game,
-- so we should be careful not to leak secret information through them
-- (e.g., the nature of the items through the total worth of inventory).
handleScores :: MonadServerChan m => Bool -> Status -> Int -> m ()
handleScores write status total =
  when (total /= 0) $ do
    config <- getsServer sconfig
    time <- getsState getTime
    curDate <- liftIO getClockTime
    slides <-
      liftIO $ register config write total time curDate status
    side <- getsState sside
    go <- sendQueryCli side $ ShowSlidesCli slides
    when (not go) abort

-- | Continue or restart or exit the game.
endOrLoop :: MonadServerChan m => m () -> m ()
endOrLoop loopServer = do
  squit <- getsServer squit
  side <- getsState sside
  gquit <- getsState $ gquit . (IM.! side) . sfaction
  s <- getState
  ser <- getServer
  faction <- getsState sfaction
  let queryCliLoc fid = sendQueryCli fid undefined -- GameSaveCli  -- TODO: do in parallel
  d <- mapM queryCliLoc $ IM.keys faction
  config <- getsServer sconfig
  let (_, total) = calculateTotal s
  -- The first, boolean component of squit determines
  -- if ending screens should be shown, the other argument describes
  -- the cause of the disruption of game flow.
  case (squit, gquit) of
    (Just _, _) -> do
      -- Save and display in parallel.
      mv <- liftIO newEmptyMVar
      liftIO $ void
        $ forkIO (Save.saveGameFile config s ser (IM.fromDistinctAscList $ zip (IM.keys faction) d)
                  `finally` putMVar mv ())
      tryIgnore $ do
        handleScores False Camping total
        broadcastPosCli [] $ MoreFullCli "See you soon, stronger and braver!"
      liftIO $ takeMVar mv  -- wait until saved
      -- Do nothing, that is, quit the game loop.
    (Nothing, Just (showScreens, status@Killed{})) -> do
      nullR <- sendQueryCli side NullReportCli
      unless nullR $ do
        -- Sisplay any leftover report. Suggest it could be the cause of death.
        broadcastPosCli [] $ MoreBWCli "Who would have thought?"
      tryWith
        (\ finalMsg ->
          let highScoreMsg = "Let's hope another party can save the day!"
              msg = if T.null finalMsg then highScoreMsg else finalMsg
          in broadcastPosCli [] $ MoreBWCli msg
          -- Do nothing, that is, quit the game loop.
        )
        (do
           when showScreens $ handleScores True status total
           go <- sendQueryCli side
                 $ ConfirmMoreBWCli "Next time will be different."
           when (not go) $ abortWith "You could really win this time."
           restartGame loopServer
        )
    (Nothing, Just (showScreens, status@Victor)) -> do
      nullR <- sendQueryCli side NullReportCli
      unless nullR $ do
        -- Sisplay any leftover report. Suggest it could be the master move.
        broadcastPosCli [] $ MoreFullCli "Brilliant, wasn't it?"
      when showScreens $ do
        tryIgnore $ handleScores True status total
        broadcastPosCli [] $ MoreFullCli "Can it be done better, though?"
      restartGame loopServer
    (Nothing, Just (_, Restart)) -> do
      broadcastPosCli [] $ MoreBWCli "This time for real."
      restartGame loopServer
    (Nothing, _) -> loopServer  -- just continue

restartGame :: MonadServerChan m => m () -> m ()
restartGame loopServer = do
  -- Take the original config from config file, to reroll RNG, if needed
  -- (the current config file has the RNG rolled for the previous game).
  cops <- getsState scops
  (state, ser, funRestart) <- gameResetAction cops
  putState state
  putServer ser
  funBroadcastCli (\fid -> let (entryLoc, sper, loc) = funRestart fid
                           in RestartCli entryLoc sper loc)
  -- TODO: send to each client RestartCli; use d in its code; empty channels?
  saveGameBkp
  loopServer

-- | Find a hero name in the config file, or create a stock name.
findHeroName :: Config -> Int -> Text
findHeroName Config{configHeroNames} n =
  let heroName = lookup n configHeroNames
  in fromMaybe ("hero number" <+> showT n) heroName

-- | Create a new hero on the current level, close to the given position.
addHero :: Kind.COps -> Point -> FactionId -> State -> StateServer
        -> (State, StateServer)
addHero Kind.COps{coactor, cotile} ppos side
        s ser@StateServer{scounter} =
  let config@Config{configBaseHP} = sconfig ser
      loc = nearbyFreePos cotile ppos s
      freeHeroK = elemIndex Nothing $ map (tryFindHeroK s) [0..9]
      n = fromMaybe 100 freeHeroK
      symbol = if n < 1 || n > 9 then '@' else Char.intToDigit n
      name = findHeroName config n
      startHP = configBaseHP - (configBaseHP `div` 5) * min 3 n
      m = template (heroKindId coactor) (Just symbol) (Just name)
                   startHP loc (getTime s) side False
  in ( updateArena (updateActor (IM.insert scounter m)) s
     , ser { scounter = scounter + 1 } )

-- | Create a set of initial heroes on the current level, at position ploc.
initialHeroes :: Kind.COps -> Point -> FactionId -> State -> StateServer
              -> (State, StateServer)
initialHeroes cops ppos side s ser =
  let Config{configExtraHeroes} = sconfig ser
      k = 1 + configExtraHeroes
  in iterate (uncurry $ addHero cops ppos side) (s, ser) !! k

-- TODO: do this inside Action ()
gameReset :: Kind.COps
          -> IO (State, StateServer, FactionId -> (Point, FactionPers, State))
gameReset cops@Kind.COps{ cofact=Kind.Ops{opick, ofoldrWithKey}
                                  , coitem
                                  , corule
                                  , costrat=Kind.Ops{opick=sopick} } = do
  -- Rules config reloaded at each new game start.
  (sconfig, dungeonGen, random) <- ConfigIO.mkConfigRules corule
  randomCli <- R.newStdGen  -- TODO: each AI client should have one
  -- from sconfig (only known to server), other clients each should have
  -- one known only to them (or server, if needed)
  let rnd = do
        sflavour <- dungeonFlavourMap coitem
        (discoS, discoRev) <- serverDiscos coitem
        DungeonGen.FreshDungeon{..} <-
          DungeonGen.dungeonGen cops sflavour discoRev sconfig
        let factionName = configFaction sconfig
        playerFactionKindId <- opick factionName (const True)
        let g gkind fk mk = do
              (m, k) <- mk
              let gname = fname fk
                  genemy = fenemy fk
                  gally = fally fk
              gAiSelected <-
                if gkind == playerFactionKindId
                then return Nothing
                else fmap Just $ sopick (fAiSelected fk) (const True)
              gAiIdle <- sopick (fAiIdle fk) (const True)
              let gquit = Nothing
              return (IM.insert k Faction{..} m, k + 1)
        faction <- fmap fst $ ofoldrWithKey g (return (IM.empty, 0))
        let defState =
              defStateGlobal freshDungeon freshDepth discoS faction
                             cops random entryLevel
            defSer = defStateServer discoRev sflavour sconfig
            needInitialCrew =
              filter (not . isSpawningFaction defState) $ IM.keys faction
            fo fid (gloF, serF) =
              initialHeroes cops entryLoc fid gloF serF
            (glo, ser) = foldr fo (defState, defSer) needInitialCrew
            -- This state is quite small, fit for transmition to the client.
            -- The biggest part is content, which really needs to be updated
            -- at this point to keep clients in sync with server improvements.
            defLoc = defStateLocal cops freshDungeon discoS
                                   freshDepth faction randomCli entryLevel
            tryFov = stryFov $ sdebugSer ser
            fovMode = fromMaybe (configFovMode sconfig) tryFov
            pers = dungeonPerception cops fovMode glo
            funReset fid = (entryLoc, pers IM.! fid, defLoc fid)
        return (glo, ser, funReset)
  return $! St.evalState rnd dungeonGen

gameResetAction :: MonadServer m
                => Kind.COps
                -> m ( State
                     , StateServer
                     , FactionId -> (Point, FactionPers, State))
gameResetAction = liftIO . gameReset

-- | Wire together content, the definitions of game commands,
-- config and a high-level startup function
-- to form the starting game session. Evaluate to check for errors,
-- in particular verify content consistency.
-- Then create the starting game config from the default config file
-- and initialize the engine with the starting session.
startFrontend :: (MonadActionAbort m, MonadActionAbort n)
              => (m () -> Pers -> State -> StateServer -> ConnDict -> IO ())
                 -> (n () -> FrontendSession -> Binding -> ConfigUI
                     -> State -> StateClient -> ConnClient -> IO ())
              -> Kind.COps -> m () -> n () -> IO ()
startFrontend executorS executorC
              !copsSlow@Kind.COps{corule, cotile=tile}
              loopServer loopClient = do
  -- Compute and insert auxiliary optimized components into game content,
  -- to be used in time-critical sections of the code.
  let ospeedup = Tile.speedup tile
      cotile = tile {Kind.ospeedup}
      cops = copsSlow {Kind.cotile}
  -- UI config reloaded at each client start.
  sconfigUI <- Client.ConfigIO.mkConfigUI corule
  -- A throw-away copy of rules config reloaded at client start, too,
  -- until an old version of the config can be read from the savefile.
  (sconfig, _, _) <- ConfigIO.mkConfigRules corule
  let !sbinding = stdBinding sconfigUI
      font = configFont sconfigUI
      -- In addition to handling the turn, if the game ends or exits,
      -- handle the history and backup savefile.
      handleServer = do
        loopServer
--        d <- getDict
--        -- Save history often, at each game exit, in case of crashes.
--        liftIO $ Save.rmBkpSaveHistory sconfig sconfigUI d
      loop sfs = start executorS executorC
                       sfs cops sbinding sconfig sconfigUI
                       handleServer loopClient
  startup font loop

-- | Either restore a saved game, or setup a new game.
-- Then call the main game loop.
start :: (MonadActionAbort m, MonadActionAbort n)
      => (m () -> Pers -> State -> StateServer -> ConnDict -> IO ())
      -> (n () -> FrontendSession -> Binding -> ConfigUI
          -> State -> StateClient -> ConnClient -> IO ())
      -> FrontendSession -> Kind.COps -> Binding -> Config -> ConfigUI
      -> m () -> n () -> IO ()
start executorS executorC sfs cops@Kind.COps{corule}
      sbinding sconfig sconfigUI handleServer loopClient = do
  let title = rtitle $ Kind.stdRuleset corule
      pathsDataFile = rpathsDataFile $ Kind.stdRuleset corule
  restored <- Save.restoreGame sconfig sconfigUI pathsDataFile title
  (glo, ser, dBare, shistory, msg) <- case restored of
    Right (shistory, msg) -> do  -- Starting a new game.
      (gloR, serR, funR) <- gameReset cops
      let faction = sfaction gloR
          d = map (\fid -> let (entryLoc, sper, loc) = funR fid
                           in (fid, (defStateClient entryLoc sper, loc)))
              $ IM.keys faction
          dR = IM.fromDistinctAscList d
      return (gloR, serR, dR, shistory, msg)
    Left (gloL, serL, dL, shistory, msg) -> do  -- Running a restored game.
      let gloCops = updateCOps (const cops) gloL
          dCops = IM.map (\(cli, loc) -> (cli, updateCOps (const cops) loc)) dL
      return (gloCops, serL, dCops, shistory, msg)
  let singMsg (cli, loc) = (cli {sreport = singletonReport msg}, loc)
      dMsg = IM.map singMsg dBare
      dHist = case filter (isPlayerFaction glo) $ IM.keys dMsg of
        [] -> dMsg  -- only robots play
        k : _ -> IM.adjust (\(cli, loc) -> (cli {shistory}, loc)) k dMsg
      tryFov = stryFov $ sdebugSer ser
      fovMode = fromMaybe (configFovMode sconfig) tryFov
      pers = dungeonPerception cops fovMode glo
      dPer = IM.mapWithKey (\side (cli, loc) ->
                               (cli {sper = pers IM.! side}, loc)) dHist
      mkConnClient = do
        toClient <- newChan
        toServer <- newChan
        return $ ConnClient {toClient, toServer}
      addChan (k, cliloc) = do
        chan <- mkConnClient
        let isPlayer = isPlayerFaction glo k
        -- For non-humans, we don't spawn a separate AI client. In this way,
        -- non-human players are allowed to cheat: their non-leader actors
        -- know leader plans and act accordingly, while human non-leader
        -- actors are controlled by an AI ignorant of human plans.
        mchan <- if isPlayer
                 then fmap Just mkConnClient
                 else return Nothing
        return (k, (cliloc, (chan, mchan)))
  dAssocs <- mapM addChan $ IM.toAscList dPer
  let d = IM.map snd $ IM.fromAscList dAssocs
      forkClient (_, ((cli, loc), (chan, mchan))) = do
        void $ forkIO
          $ executorC loopClient sfs sbinding sconfigUI loc cli chan
        case mchan of
          Nothing -> return ()
          Just ch ->
            -- The AI client does not know it's not the main client.
            void $ forkIO
              $ executorC loopClient sfs sbinding sconfigUI loc cli ch
  mapM_ forkClient dAssocs
  executorS handleServer pers glo ser d

switchGlobalSelectedSide :: MonadServer m => FactionId -> m ()
switchGlobalSelectedSide =
  modifyState . switchGlobalSelectedSideOnlyForGlobalState

connSendUpdateCli :: MonadServerChan m => ConnClient -> CmdUpdateCli -> m ()
connSendUpdateCli ConnClient {toClient} cmd =
  liftIO $ writeChan toClient $ CmdUpdateCli cmd

sendUpdateCli :: MonadServerChan m => FactionId -> CmdUpdateCli -> m ()
sendUpdateCli fid cmd = do
  conn <- getsDict (fst . (IM.! fid))
  connSendUpdateCli conn cmd

connSendQueryCli :: (Typeable a, MonadServerChan m)
                 => ConnClient -> CmdQueryCli a
                 -> m a
connSendQueryCli ConnClient {toClient, toServer} cmd = do
  liftIO $ writeChan toClient $ CmdQueryCli cmd
  a <- liftIO $ readChan toServer
  return $ fromDyn a (assert `failure` (cmd, a))

sendQueryCli :: (Typeable a, MonadServerChan m)
             => FactionId -> CmdQueryCli a
             -> m a
sendQueryCli fid cmd = do
  conn <- getsDict (fst . (IM.! fid))
  connSendQueryCli conn cmd

sendAIQueryCli :: (Typeable a, MonadServerChan m)
                  => FactionId -> CmdQueryCli a
                  -> m a
sendAIQueryCli fid cmd = do
  connFaction <- getsDict (IM.! fid)
  -- Prefer the AI client, if it exists.
  let conn = fromMaybe (fst connFaction) (snd connFaction)
  connSendQueryCli conn cmd

broadcastCli :: MonadServerChan m
             => [FactionId -> m Bool] -> CmdUpdateCli
             -> m ()
broadcastCli ps cmd = do
  faction <- getsState sfaction
  let p fid = do
        bs <- sequence $ map (\f -> f fid) ps
        return $! and bs
  ks <- filterM p $ IM.keys faction
  mapM_ (flip sendUpdateCli cmd) ks

isFactionPlayer :: MonadServerChan m => FactionId -> m Bool
isFactionPlayer fid = getsState $ flip isPlayerFaction fid

isFactionAware :: MonadServerChan m => [Point] -> FactionId -> m Bool
isFactionAware poss fid = do
  arena <- getsState sarena
  pers <- ask
  let per = pers IM.! fid M.! arena
      inter = IS.fromList poss `IS.intersection` totalVisible per
  return $! null poss || not (IS.null inter)

broadcastPosCli :: MonadServerChan m => [Point] -> CmdUpdateCli -> m ()
broadcastPosCli poss cmd =
  broadcastCli [isFactionPlayer, isFactionAware poss] cmd

funBroadcastCli :: MonadServerChan m => (FactionId -> CmdUpdateCli) -> m ()
funBroadcastCli cmd = do
  faction <- getsState sfaction
  let f fid = sendUpdateCli fid (cmd fid)
  mapM_ f $ IM.keys faction

funAIBroadcastCli :: MonadServerChan m => (FactionId -> CmdUpdateCli) -> m ()
funAIBroadcastCli cmd = do
  faction <- getsState sfaction
  d <- getDict
  let f fid = case snd $ d IM.! fid of
        Nothing -> return ()
        Just conn -> connSendUpdateCli conn (cmd fid)
  mapM_ f $ IM.keys faction
