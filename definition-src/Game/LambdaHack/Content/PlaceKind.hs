{-# LANGUAGE DeriveGeneric #-}
-- | The type of place kinds. Every room in the game is an instantiated
-- place kind.
module Game.LambdaHack.Content.PlaceKind
  ( PlaceKind(..), makeData
  , Cover(..), Fence(..)
  , PlaceEntry(..), deadEndId
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , validateSingle, validateAll
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Data.Binary
import qualified Data.EnumMap.Strict as EM
import qualified Data.Text as T
import           GHC.Generics (Generic)

import Game.LambdaHack.Content.TileKind (TileKind)
import Game.LambdaHack.Definition.ContentData
import Game.LambdaHack.Definition.Defs
import Game.LambdaHack.Definition.DefsInternal

-- | Parameters for the generation of small areas within a dungeon level.
data PlaceKind = PlaceKind
  { psymbol     :: Char          -- ^ a symbol
  , pname       :: Text          -- ^ short description, singular or plural
  , pfreq       :: Freqs PlaceKind  -- ^ frequency within groups
  , prarity     :: Rarity        -- ^ rarity on given depths
  , pcover      :: Cover         -- ^ how to fill whole place using the corner
  , pfence      :: Fence         -- ^ whether to fence place with solid border
  , ptopLeft    :: [Text]        -- ^ plan of the top-left corner of the place
  , plegendDark :: EM.EnumMap Char (GroupName TileKind)  -- ^ dark legend
  , plegendLit  :: EM.EnumMap Char (GroupName TileKind)  -- ^ lit legend
  }
  deriving Show  -- No Eq and Ord to make extending logically sound

-- | A method of filling the whole area (except for CVerbatim and CMirror,
-- which are just placed in the middle of the area) by transforming
-- a given corner.
data Cover =
    CAlternate  -- ^ reflect every other corner, overlapping 1 row and column
  | CStretch    -- ^ fill symmetrically 4 corners and stretch their borders
  | CReflect    -- ^ tile separately and symmetrically quarters of the place
  | CVerbatim   -- ^ just build the given interior, without filling the area
  | CMirror     -- ^ build the given interior in one of 4 mirrored variants
  deriving (Show, Eq)

-- | The choice of a fence type for the place.
data Fence =
    FWall   -- ^ put a solid wall fence around the place
  | FFloor  -- ^ leave an empty space, like the room's floor
  | FGround -- ^ leave an empty space, like the cave's ground
  | FNone   -- ^ skip the fence and fill all with the place proper
  deriving (Show, Eq)

data PlaceEntry =
    PEntry (ContentId PlaceKind)
  | PAround (ContentId PlaceKind)
  | PExists (ContentId PlaceKind)
  deriving (Show, Eq, Generic)

instance Binary PlaceEntry

deadEndId :: ContentId PlaceKind
{-# INLINE deadEndId #-}
deadEndId = toContentId 0

-- | Catch invalid place kind definitions. In particular, verify that
-- the top-left corner map is rectangular and not empty.
validateSingle :: PlaceKind -> [Text]
validateSingle PlaceKind{..} =
  let dxcorner = case ptopLeft of
        [] -> 0
        l : _ -> T.length l
  in [ "top-left corner empty" | dxcorner == 0 ]
     ++ [ "top-left corner not rectangular"
        | any (/= dxcorner) (map T.length ptopLeft) ]
     ++ validateRarity prarity

-- | Validate all place kinds.
validateAll :: [PlaceKind] -> ContentData PlaceKind -> [Text]
validateAll _ _ = []  -- so far, always valid

makeData :: [PlaceKind] -> [GroupName PlaceKind] -> [GroupName PlaceKind]
         -> ContentData PlaceKind
makeData = makeContentData "PlaceKind" pname pfreq validateSingle validateAll
