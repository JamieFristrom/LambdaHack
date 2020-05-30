{-# LANGUAGE RankNTypes, TypeFamilies #-}
-- | Screen frames.
module Game.LambdaHack.Client.UI.Frame
  ( ColorMode(..)
  , FrameST, FrameForall(..), FrameBase(..), Frame
  , PreFrame3, PreFrames3, PreFrame, PreFrames
  , SingleFrame(..), OverlaySpace
  , blankSingleFrame, truncateOverlay, overlayFrame
#ifdef EXPOSE_INTERNAL
    -- * Internal operations
  , truncateAttrLine
#endif
  ) where

import Prelude ()

import Game.LambdaHack.Core.Prelude

import           Control.Monad.ST.Strict
import qualified Data.IntMap.Strict as IM
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as VM
import           Data.Word

import           Game.LambdaHack.Client.UI.Content.Screen
import           Game.LambdaHack.Client.UI.Key (PointUI (..))
import           Game.LambdaHack.Client.UI.Overlay
import qualified Game.LambdaHack.Common.PointArray as PointArray
import qualified Game.LambdaHack.Definition.Color as Color

-- | Color mode for the display.
data ColorMode =
    ColorFull  -- ^ normal, with full colours
  | ColorBW    -- ^ black and white only
  deriving Eq

type FrameST s = G.Mutable U.Vector s Word32 -> ST s ()

-- | Efficiently composable representation of an operation
-- on a frame, that is, on a mutable vector. When the composite operation
-- is eventually performed, the vector is frozen to become a 'SingleFrame'.
newtype FrameForall = FrameForall {unFrameForall :: forall s. FrameST s}

-- | Action that results in a base frame, to be modified further.
newtype FrameBase = FrameBase
  {unFrameBase :: forall s. ST s (G.Mutable U.Vector s Word32)}

-- | A frame, that is, a base frame and all its modifications.
type Frame = ((FrameBase, FrameForall), (OverlaySpace, OverlaySpace))

-- | Components of a frame, before it's decided if the first can be overwritten
-- in-place or needs to be copied.
type PreFrame3 = (PreFrame, (OverlaySpace, OverlaySpace))

-- | Sequence of screen frames, including delays. Potentially based on a single
-- base frame.
type PreFrames3 = [Maybe PreFrame3]

-- | A simpler variant of @PreFrame3@.
type PreFrame = (U.Vector Word32, FrameForall)

-- | A simpler variant of @PreFrames3@.
type PreFrames = [Maybe PreFrame]

-- | Representation of an operation of overwriting a frame with a single line
-- at the given row.
writeLine :: Int -> AttrString -> FrameForall
{-# INLINE writeLine #-}
writeLine offset al = FrameForall $ \v -> do
  let writeAt _ [] = return ()
      writeAt off (ac32 : rest) = do
        VM.write v off (Color.attrCharW32 ac32)
        writeAt (off + 1) rest
  writeAt offset al

-- | A frame that is padded to fill the whole screen with an optional
-- overlay to display in proportional font.
--
-- Note that we don't provide a list of color-highlighed box positions
-- to be drawn separately, because overlays need to obscure not only map,
-- but the highlights as well, so highlights need to be included earlier.
data SingleFrame = SingleFrame
  { singleArray       :: PointArray.Array Color.AttrCharW32
  , singlePropOverlay :: OverlaySpace
  , singleMonoOverlay :: OverlaySpace }
  deriving (Eq, Show)

type OverlaySpace = [(PointUI, AttrString)]

blankSingleFrame :: ScreenContent -> SingleFrame
blankSingleFrame ScreenContent{rwidth, rheight} =
  SingleFrame (PointArray.replicateA rwidth rheight Color.spaceAttrW32)
              []
              []

-- | Truncate the overlay: for each line, if it's too long, it's truncated
-- and if there are too many lines, excess is dropped and warning is appended.
-- The width, in the second argument, is calculated in characters,
-- not in UI (mono font) coordinates, so that taking and dropping characters
-- is performed correctly.
truncateOverlay :: Bool -> Int -> Int -> Bool -> Int -> Bool -> Overlay
                -> OverlaySpace
truncateOverlay halveXstart width rheight wipeAdjacent fillLen onBlank ov =
  let canvasLength = if onBlank then rheight else rheight - 2
      supHeight = maximum $ 0 : map (\(PointUI _ y, _) -> y) ov
      trimmedY = canvasLength - 1
      ovTopFiltered = filter (\(PointUI _ y, _) -> y < trimmedY) ov
      trimmedAlert = ( PointUI 0 trimmedY
                     , stringToAL "--a portion of the text trimmed--" )
      extraLine | supHeight < 3
                  || supHeight >= trimmedY
                  || not wipeAdjacent
                  || onBlank = []
                | otherwise =
        case find (\(PointUI _ y, _) -> y == supHeight) ov of
          Nothing -> []
          Just (PointUI xLast yLast, _) ->
            [(PointUI xLast (yLast + 1), emptyAttrLine)]
      ovTop = IM.elems $ IM.fromListWith (++)
              $ map (\pal@(PointUI _ y, _) -> (y, [pal]))
              $ if supHeight >= canvasLength
                then ovTopFiltered ++ [trimmedAlert]
                else ov ++ extraLine
      -- Unlike the trimming above, adding spaces around overlay depends
      -- on there being no gaps and a natural order.
      -- Probably also gives messy results when X offsets are not all the same.
      -- Below we at least mitigate the case of multiple lines per row.
      f lenPrev lenNext lal =
        -- This is crude, because an al at lower x may be longer, but KISS.
        case sortOn (\(PointUI x _, _) -> x) lal of
          [] -> error "empty list of overlay lines at the given row"
          maxAl : rest ->
            g lenPrev lenNext fillLen maxAl
            : map (g 0 0 0) rest
      g lenPrev lenNext fillL (p@(PointUI xstartRaw _), layerLine) =
        let xstart = if halveXstart then xstartRaw `div` 2 else xstartRaw
            maxLen = if wipeAdjacent then max lenPrev lenNext else 0
            fillFromStart = max fillL (1 + maxLen) - xstart
            available = width - xstart
        in (p, truncateAttrLine available fillFromStart layerLine)
      rightExtentOfLine (PointUI xstartRaw _, al) =
        let xstart = if halveXstart then xstartRaw `div` 2 else xstartRaw
        in min (width - 1) (xstart + length (attrLine al))
      lens = map (maximum . map rightExtentOfLine) ovTop
      f2 = map g2
      g2 (p@(PointUI xstartRaw _), layerLine) =
        let xstart = if halveXstart then xstartRaw `div` 2 else xstartRaw
            available = width - xstart
        in (p, truncateAttrLine available 0 layerLine)
  in concat $ if onBlank
              then map f2 ovTop
              else zipWith3 f (0 : lens) (drop 1 lens ++ [0]) ovTop

-- | Add a space at the message end, for display overlayed over the level map.
-- Also trim (do not wrap!) too long lines. Also add many spaces when under
-- longer lines.
truncateAttrLine :: Int -> Int -> AttrLine -> AttrString
truncateAttrLine available fillFromStart aLine =
  let al = attrLine aLine
      len = length al
  in if | len == available - 1 -> al ++ [Color.spaceAttrW32]
        | otherwise -> case compare available len of
            LT -> take (available - 1) al ++ [Color.trimmedLineAttrW32]
            EQ -> al
            GT -> let alSpace = al ++ [Color.spaceAttrW32, Color.spaceAttrW32]
                      whiteN = fillFromStart - len - 2
                  in if whiteN <= 0  -- speedup (supposedly) for menus
                     then alSpace
                     else alSpace ++ replicate whiteN Color.spaceAttrW32

-- | Overlays either the game map only or the whole empty screen frame.
-- We assume the lines of the overlay are not too long nor too many.
overlayFrame :: Int -> OverlaySpace -> PreFrame -> PreFrame
overlayFrame width ov (m, ff) =
  ( m
  , FrameForall $ \v -> do
      unFrameForall ff v
      mapM_ (\(PointUI px py, l) ->
               let offset = py * width + px `div` 2
               in unFrameForall (writeLine offset l) v) ov )
