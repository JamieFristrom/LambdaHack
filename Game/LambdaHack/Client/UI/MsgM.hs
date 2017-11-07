-- | Client monad for interacting with a human through UI.
module Game.LambdaHack.Client.UI.MsgM
  ( msgAdd, promptAdd, promptMainKeys, promptAddAttr, recordHistory
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.MonadClientUI
import Game.LambdaHack.Client.UI.Msg
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.State

-- | Add a message to the current report.
msgAdd :: MonadClientUI m => Text -> m ()
msgAdd msg = modifySession $ \sess ->
  sess {_sreport = snocReport (_sreport sess) (toMsg $ textToAL msg)}

-- | Add a prompt to the current report.
promptAdd :: MonadClientUI m => Text -> m ()
promptAdd msg = modifySession $ \sess ->
  sess {_sreport = snocReport (_sreport sess) (toPrompt $ textToAL msg)}

promptMainKeys :: MonadClientUI m => m ()
promptMainKeys = do
  saimMode <- getsSession saimMode
  Config{configVi, configLaptop} <- getsSession sconfig
  xhair <- getsSession sxhair
  let moveKeys | configVi = "keypad or hjklyubn"
               | configLaptop = "keypad or uk8o79jl"
               | otherwise = "keypad"
      keys | isNothing saimMode =
        "Explore with" <+> moveKeys <+> "keys or mouse."
           | otherwise =
        "Aim" <+> tgtKindDescription xhair
        <+> "with" <+> moveKeys <+> "keys or mouse."
  promptAdd keys

-- | Add a prompt to the current report.
promptAddAttr :: MonadClientUI m => AttrLine -> m ()
promptAddAttr msg = modifySession $ \sess ->
  sess {_sreport = snocReport (_sreport sess) (toPrompt msg)}

-- | Store current report in the history and reset report.
recordHistory :: MonadClientUI m => m ()
recordHistory = do
  time <- getsState stime
  SessionUI{_sreport, shistory} <- getSession
  unless (nullReport _sreport) $ do
    let nhistory = addReport shistory time _sreport
    modifySession $ \sess -> sess { _sreport = emptyReport
                                  , shistory = nhistory }
