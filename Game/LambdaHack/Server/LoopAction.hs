{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | The main loop of the server, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Server.LoopAction (loopSer) where

import Control.Arrow ((&&&))
import Control.Monad
import Control.Monad.Writer.Strict (WriterT, execWriterT)
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import Data.Maybe
import qualified Data.Ord as Ord

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.AtomicCmd
import Game.LambdaHack.ClientCmd
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Feature as F
import Game.LambdaHack.Item
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Perception
import Game.LambdaHack.Point
import Game.LambdaHack.Random
import Game.LambdaHack.Server.Action hiding (sendUpdateAI, sendUpdateUI)
import Game.LambdaHack.Server.AtomicSemSer
import Game.LambdaHack.Server.EffectSem
import Game.LambdaHack.Server.ServerSem
import Game.LambdaHack.Server.StartAction
import Game.LambdaHack.Server.State
import Game.LambdaHack.ServerCmd
import Game.LambdaHack.State
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Time
import Game.LambdaHack.Utils.Assert

-- | Start a clip (a part of a turn for which one or more frames
-- will be generated). Do whatever has to be done
-- every fixed number of time units, e.g., monster generation.
-- Run the leader and other actors moves. Eventually advance the time
-- and repeat.
loopSer :: (MonadAction m, MonadServerConn m)
        => DebugModeSer
        -> (CmdSer -> m [Atomic])
        -> (FactionId -> Conn CmdClientUI -> IO ())
        -> (FactionId -> Conn CmdClientAI -> IO ())
        -> Kind.COps
        -> m ()
loopSer sdebugNxt cmdSerSem executorUI executorAI !cops = do
  -- Recover states.
  restored <- tryRestore cops
  -- TODO: use the _msg somehow
  case restored of
    Right _msg -> do  -- Starting a new game.
      -- Set up commandline debug mode
      modifyServer $ \ser -> ser {sdebugNxt}
      gameReset cops
      initConn sdebugNxt executorUI executorAI
      execAtomic reinitGame
      -- Save ASAP in case of crashes and disconnects.
      saveBkpAll
    Left (gloRaw, ser, _msg) -> do  -- Running a restored game.
      putState $ updateCOps (const cops) gloRaw
      putServer ser {sdebugNxt}
      initConn sdebugNxt executorUI executorAI
      pers <- getsServer sper
      execAtomic $ broadcastCmdAtomic $ \fid -> ResumeA fid (pers EM.! fid)
  -- Loop.
  let loop = do
        let run arena = handleActors cmdSerSem arena timeZero
            factionArena fac =
              case gleader fac of
                Nothing -> return Nothing
                Just leader -> do
                  b <- getsState $ getActorBody leader
                  return $ Just $ blid b
        faction <- getsState sfaction
        marenas <- mapM factionArena $ EM.elems faction
        let arenas = ES.toList $ ES.fromList $ catMaybes marenas
        assert (not $ null arenas) skip
        mapM_ run arenas
        execAtomic $ endClip arenas
        endOrLoop loop
  loop

execAtomic :: (MonadAction m, MonadServerConn m)
           => WriterT [Atomic] m () -> m ()
execAtomic m = do
 cmds <- execWriterT m
 mapM_ atomicSendSem cmds

saveBkpAll :: (MonadAction m, MonadServerConn m) => m ()
saveBkpAll = do
  atomicSendSem $ CmdAtomic SaveBkpA
  saveGameBkp

endClip :: MonadServer m => [LevelId] -> WriterT [Atomic] m ()
endClip arenas = do
  quitS <- getsServer squit
  -- If save&exit, don't age levels, since possibly not all actors have moved.
  unless (quitS == Just True) $ do
    time <- getsState stime
    let clipN = time `timeFit` timeClip
        cinT = let r = timeTurn `timeFit` timeClip
               in assert (r > 2) r
        bkpFreq = cinT * 100
        clipMod = clipN `mod` cinT
    when (quitS == Just False || clipN `mod` bkpFreq == 0) $ do
      tellCmdAtomic SaveBkpA
      saveGameBkp
      modifyServer $ \ser1 -> ser1 {squit = Nothing}
    -- Regenerate HP and add monsters each turn, not each clip.
    when (clipMod == 1) $ mapM_ generateMonster arenas
    when (clipMod == 2) $ mapM_ regenerateLevelHP arenas
    -- TODO: a couple messages each clip to many clients is too costly
    mapM_ (\lid -> tellCmdAtomic $ AgeLevelA lid timeClip) arenas
    tellCmdAtomic $ AgeGameA timeClip

-- | Perform moves for individual actors, as long as there are actors
-- with the next move time less than or equal to the current time.
-- Some very fast actors may move many times a clip and then
-- we introduce subclips and produce many frames per clip to avoid
-- jerky movement. Otherwise we push exactly one frame or frame delay.
-- We start by updating perception, because the selected level of dungeon
-- has changed since last time (every change, whether by human or AI
-- or @generateMonster@ is followd by a call to @handleActors@).
handleActors :: (MonadAction m, MonadServerConn m)
             => (CmdSer -> m [Atomic])
             -> LevelId
             -> Time  -- ^ start time of current subclip, exclusive
             -> m ()
handleActors cmdSerSem arena subclipStart = do
  Kind.COps{coactor} <- getsState scops
  time <- getsState $ getLocalTime arena  -- the end time of this clip, inclusive
  prio <- getsLevel arena lprio
  quitS <- getsServer squit
  faction <- getsState sfaction
  s <- getState
  let mnext =
        let -- Actors of the same faction move together.
            -- TODO: insert wrt order, instead of sorting
            isLeader (a1, b1) =
              not $ Just a1 == gleader (faction EM.! bfaction b1)
            order = Ord.comparing $ ((>= 0) . bhp . snd) &&& bfaction . snd
                                    &&& isLeader &&& bsymbol . snd
            (atime, as) = EM.findMin prio
            ams = map (\a -> (a, getActorBody a s)) as
            (actor, m) = head $ sortBy order ams
        in if atime > time
           then Nothing  -- no actor is ready for another move
           else Just (actor, m)
  case mnext of
    _ | isJust quitS -> return ()
    Nothing -> do
-- Disabled until the code is stable, not to pollute commands debug logs:
--      when (subclipStart == timeZero) $
--        mapM_ atomicSendSem $ map (Right . DisplayDelayD) $ EM.keys faction
      return ()
    Just (aid, b) | bhp b <= 0 && not (bproj b) || bhp b < 0
                    || maybe False null (bpath b) -> do
      execAtomic $
        if bproj b && bhp b < 0  -- a projectile hitting an actor
        then do
          -- Items are destroyed.
          ais <- getsState $ getActorItem aid
          tellCmdAtomic $ DestroyActorA aid b ais
        else
          -- Items drop to the ground and new leader elected.
          dieSer aid
      -- Death or projectile impact are serious, new subclip.
      handleActors cmdSerSem arena (btime b)
    Just (actor, body) -> do
      -- TODO: too often, at least in multiplayer
      execAtomic $ broadcastSfxAtomic DisplayPushD
      let side = bfaction body
          fac = faction EM.! side
          mleader = gleader fac
          isHuman = isHumanFact fac
          usesAI = usesAIFact fac
          hasHumanLeader = isNothing $ gAiLeader fac
      if not usesAI || hasHumanLeader && Just actor == mleader
        then do
          -- TODO: check that the command is legal, that is, correct side, etc.
          cmdS <- sendQueryUI side actor
          atoms <- cmdSerSem cmdS
          let isFailure cmd =
                case cmd of SfxAtomic FailureD{} -> True; _ -> False
              aborted = all isFailure atoms
              timed = timedCmdSer cmdS
              leaderNew = aidCmdSer cmdS
              leadAtoms =
                if leaderNew /= actor
                then [CmdAtomic (LeadFactionA side mleader (Just leaderNew))]
                else []
          nH <- nHumans
          -- TODO: do not fade out if all other are running (so the previous
          -- move was of the same actor)
          let fadeOut | nH > 1 =
                -- More than one human player, mark end of turn.
                [ SfxAtomic $ FadeoutD side True
                , SfxAtomic $ FlushFramesD side
                , SfxAtomic $ FadeinD side True ]
                   | otherwise =
                -- At most one human player, no need to send anything.
                []
          advanceAtoms <- if aborted || not timed
                          then return []
                          else fmap (++ fadeOut) $ advanceTime leaderNew
          mapM_ atomicSendSem $ leadAtoms ++ atoms ++ advanceAtoms
          if aborted then handleActors cmdSerSem arena subclipStart
          else do
            -- Advance time once, after the leader switched perhaps many times.
            -- TODO: this is correct only when all heroes have the same
            -- speed and can't switch leaders by, e.g., aiming a wand
            -- of domination. We need to generalize by displaying
            -- "(next move in .3s [RET]" when switching leaders.
            -- RET waits .3s and gives back control,
            -- Any other key does the .3s wait and the action form the key
            -- at once. This requires quite a bit of refactoring
            -- and is perhaps better done when the other factions have
            -- selected leaders as well.
            bNew <- getsState $ getActorBody leaderNew
            -- Human moves always start a new subclip.
            -- TODO: send messages with time (or at least DisplayPushCli)
            -- and then send DisplayPushCli only to actors that see _pos.
            -- Right now other need it too, to notice the delay.
            -- This will also be more accurate since now unseen
            -- simultaneous moves also generate delays.
            -- TODO: when changing leaders of different levels, if there's
            -- abort, a turn may be lost. Investigate/fix.
            handleActors cmdSerSem arena (btime bNew)
        else do
          cmdS <- sendQueryAI side actor
          atoms <- cmdSerSem cmdS
          let isFailure cmd =
                case cmd of SfxAtomic FailureD{} -> True; _ -> False
              aborted = all isFailure atoms
              timed = timedCmdSer cmdS
              leaderNew = aidCmdSer cmdS
              leadAtoms =
                if leaderNew /= actor
                then -- Only leader can change leaders
                     assert (mleader == Just actor)
                       [CmdAtomic (LeadFactionA side mleader (Just leaderNew))]
                else []
          advanceAtoms <- if aborted || not timed
                          then return []
                          else advanceTime leaderNew
          mapM_ atomicSendSem $ leadAtoms ++ atoms ++ advanceAtoms
          let subclipStartDelta = timeAddFromSpeed coactor body subclipStart
          if not aborted && isHuman && not (bproj body)
             || subclipStart == timeZero
             || btime body > subclipStartDelta
            then do
              -- Start a new subclip if its our own faction moving
              -- or it's another faction, but it's the first move of
              -- this whole clip or the actor has already moved during
              -- this subclip, so his multiple moves would be collapsed.
    -- If the following action aborts, we just advance the time and continue.
    -- TODO: or just fail at each abort in AI code? or use tryWithFrame?
              bNew <- getsState $ getActorBody leaderNew
              handleActors cmdSerSem arena (btime bNew)
            else
              -- No new subclip.
    -- If the following action aborts, we just advance the time and continue.
    -- TODO: or just fail at each abort in AI code? or use tryWithFrame?
              handleActors cmdSerSem arena subclipStart

dieSer :: MonadActionRO m => ActorId -> WriterT [Atomic] m ()
dieSer aid = do  -- TODO: explode if a projectile holding a potion
  body <- getsState $ getActorBody aid
  -- TODO: clients don't see the death of their last standing actor;
  --       modify Draw.hs and Client.hs to handle that
  electLeader (bfaction body) (blid body) aid
  dropAllItems aid body
  tellCmdAtomic $ DestroyActorA aid body {bbag = EM.empty} []
--  Config{configFirstDeathEnds} <- getsServer sconfig

-- | Drop all actor's items.
dropAllItems :: MonadActionRO m => ActorId -> Actor -> WriterT [Atomic] m ()
dropAllItems aid b = do
  let f (iid, k) = tellCmdAtomic
                   $ MoveItemA iid k (actorContainer aid (binv b) iid)
                                     (CFloor (blid b) (bpos b))
  mapM_ f $ EM.assocs $ bbag b

electLeader :: MonadActionRO m
            => FactionId -> LevelId -> ActorId -> WriterT [Atomic] m ()
electLeader fid lid aidDead = do
  mleader <- getsState $ gleader . (EM.! fid) . sfaction
  when (isNothing mleader || mleader == Just aidDead) $ do
    actorD <- getsState sactorD
    let ours (_, b) = bfaction b == fid && not (bproj b)
        party = filter ours $ EM.assocs actorD
    onLevel <- getsState $ actorNotProjAssocs (== fid) lid
    let mleaderNew = listToMaybe $ filter (/= aidDead)
                     $ map fst $ onLevel ++ party
    tellCmdAtomic $ LeadFactionA fid mleader mleaderNew

-- | Advance the move time for the given actor.
advanceTime :: MonadActionRO m => ActorId -> m [Atomic]
advanceTime aid = do
  Kind.COps{coactor} <- getsState scops
  b <- getsState $ getActorBody aid
  -- TODO: Add an option to block this for non-projectiles too.
  if bhp b < 0 && bproj b then return [] else do
    let speed = actorSpeed coactor b
        t = ticksPerMeter speed
    return [CmdAtomic $ AgeActorA aid t]

-- | Generate a monster, possibly.
generateMonster :: MonadServer m => LevelId -> WriterT [Atomic] m ()
generateMonster arena = do
  cops@Kind.COps{cofact=Kind.Ops{okind}} <- getsState scops
  pers <- getsServer sper
  lvl@Level{ldepth} <- getsLevel arena id
  faction <- getsState sfaction
  s <- getState
  let f fid = fspawn (okind (gkind (faction EM.! fid))) > 0
      spawns = actorNotProjList f arena s
  rc <- rndToAction $ monsterGenChance ldepth (length spawns)
  when rc $ do
    let allPers =
          ES.unions $ map (totalVisible . (EM.! arena)) $ EM.elems pers
    pos <- rndToAction $ rollSpawnPos cops allPers arena lvl s
    spawnMonsters [pos] arena

rollSpawnPos :: Kind.COps -> ES.EnumSet Point -> LevelId -> Level -> State
             -> Rnd Point
rollSpawnPos Kind.COps{cotile} visible lid Level{ltile, lxsize, lstair} s = do
  let cminStairDist = chessDist lxsize (fst lstair) (snd lstair)
      inhabitants = actorNotProjList (const True) lid s
      isLit = Tile.isLit cotile
      distantAtLeast d l _ =
        all (\b -> chessDist lxsize (bpos b) l > d) inhabitants
  findPosTry 40 ltile
    [ distantAtLeast cminStairDist
    , \ _ t -> not (isLit t)
    , distantAtLeast $ cminStairDist `div` 2
    , \ l _ -> not $ l `ES.member` visible
    , distantAtLeast $ cminStairDist `div` 4
    , \ l t -> Tile.hasFeature cotile F.Walkable t
               && unoccupied (actorList (const True) lid s) l
    ]

-- TODO: generalize to any list of items (or effects) applied to all actors
-- every turn. Specify the list per level in config.
-- TODO: use itemEffect or at least effectSem to get from Regeneration
-- to HealActorA. Also, Applying an item with Regeneration should do the same
-- thing, but immediately (and destroy the item).
-- | Possibly regenerate HP for all actors on the current level.
--
-- We really want leader selection to be a purely UI distinction,
-- so all actors need to regenerate, not just the leaders.
-- Actors on frozen levels don't regenerate. This prevents cheating
-- via sending an actor to a safe level and letting him regenerate there.
regenerateLevelHP :: MonadServer m => LevelId -> WriterT [Atomic] m ()
regenerateLevelHP arena = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  time <- getsState $ getLocalTime arena
  s <- getState
  let pick (a, m) =
        let ak = okind $ bkind m
            itemAssocs = getActorItem a s
            regen = max 1 $
                      aregen ak `div`
                      case strongestRegen itemAssocs of
                        Just (k, _)  -> k + 1
                        Nothing -> 1
            bhpMax = maxDice (ahp ak)
            deltaHP = min 1 (bhpMax - bhp m)
        in if (time `timeFit` timeTurn) `mod` regen /= 0 || deltaHP <= 0
           then Nothing
           else Just a
  toRegen <-
    getsState $ catMaybes . map pick . actorNotProjAssocs (const True) arena
  mapM_ (\aid -> tellCmdAtomic $ HealActorA aid 1) toRegen

-- | Continue or restart or exit the game.
endOrLoop :: (MonadAction m, MonadServerConn m) => m () -> m ()
endOrLoop loopServer = do
  faction <- getsState sfaction
  quitS <- getsServer squit
  let f (_, Faction{gquit=Nothing}) = Nothing
      f (fid, Faction{gquit=Just quit}) = Just (fid, quit)
  case mapMaybe f $ EM.assocs faction of
    _ | quitS == Just True -> do  -- save and exit
      execAtomic $ tellCmdAtomic SaveExitA
      saveGameSer
      -- Do nothing, that is, quit the game loop.
    quits -> processQuits loopServer quits

processQuits :: (MonadAction m, MonadServerConn m)
             => m () -> [(FactionId, (Bool, Status))] -> m ()
processQuits loopServer [] = loopServer  -- just continue
processQuits loopServer ((fid, quit) : quits) = do
  cops <- getsState scops
  faction <- getsState sfaction
  let fac = faction EM.! fid
  total <- case gleader fac of
    Nothing -> return 0
    Just leader -> do
      b <- getsState $ getActorBody leader
      getsState $ snd . calculateTotal fid (blid b)
  case snd quit of
    status@Killed{} -> do
      let inGame fact = case gquit fact of
            Just (_, Killed{}) -> False
            Just (_, Victor) -> False
            _ -> True
          notSpawning fact = not $ isSpawningFact cops fact
          isActive fact = inGame fact && notSpawning fact
          isAllied fid1 fact = fid1 `elem` gally fact
          inGameHuman fact = inGame fact && isHumanFact fact
          gameHuman = filter inGameHuman $ EM.elems faction
          gameOver = case filter (isActive . snd) $ EM.assocs faction of
            _ | null gameHuman -> True  -- no screensaver mode for now
            [] -> True
            (fid1, fact1) : rest ->
              -- Competitive game ends when only one allied team remains.
              all (isAllied fid1 . snd) rest
              -- Cooperative game continues until the last ally dies.
              && not (isAllied fid fact1)
      if gameOver then do
        registerScore status total
        restartGame loopServer
      else
        processQuits loopServer quits
    status@Victor -> do
      registerScore status total
      restartGame loopServer
    Restart -> restartGame loopServer
    Camping -> assert `failure` (fid, quit)

restartGame :: (MonadAction m, MonadServerConn m) => m () -> m ()
restartGame loopServer = do
  cops <- getsState scops
  nH <- nHumans
  when (nH <= 1) $ execAtomic $ broadcastSfxAtomic $ \fid -> FadeoutD fid False
  gameReset cops
  initPer
  execAtomic reinitGame
  -- Save ASAP in case of crashes and disconnects.
  saveBkpAll
  loopServer
