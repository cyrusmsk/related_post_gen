{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}

module RelatedPostGen (module RelatedPostGen) where

import Control.DeepSeq (NFData)
import Control.Monad (when)
import Control.Monad.ST.Strict (ST)

import Data.Aeson (FromJSON, ToJSON)
import Data.Bits (Bits (shiftL, shiftR, (.&.), (.|.)))
import Data.Kind (Type)
import Data.STRef.Unboxed (STRefU, newSTRefU, readSTRefU, writeSTRefU)
import Data.Text (Text)
import Data.Vector qualified as V
import Data.Vector.Hashtables qualified as H
import Data.Vector.Mutable qualified as VM
import Data.Vector.Primitive.Mutable qualified as VPM
import Data.Word (Word32, Word64, Word8)

import GHC.Generics (Generic)

type HashTable :: Type -> Type -> Type -> Type
type HashTable s k v = H.Dictionary (H.PrimState (ST s)) VM.MVector k VM.MVector v

type TagMap :: Type -> Type
type TagMap s = HashTable s Text (VPM.STVector s Word32)

type Post :: Type
data Post = MkPost
  { _id :: !Text
  , tags :: !(V.Vector Text)
  , title :: !Text
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON, NFData)

type RelatedPosts :: Type
data RelatedPosts = MkRelatedPosts
  { _id :: !Text
  , tags :: !(V.Vector Text)
  , related :: !(V.Vector Post)
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON, NFData)

limitTopN :: Int
limitTopN = 5

computeRelatedPosts :: V.Vector Post -> ST s (V.Vector RelatedPosts)
computeRelatedPosts posts = do
  !tagMap :: TagMap s <- H.initialize 0
  let !postsIdx = V.indexed posts
  populateTagMap tagMap postsIdx
  buildRelatedPosts posts postsIdx tagMap
{-# INLINE computeRelatedPosts #-}

populateTagMap :: TagMap s -> V.Vector (Int, Post) -> ST s ()
populateTagMap tagMap postsIdx = do
  V.forM_ postsIdx \(i, MkPost{tags}) ->
    V.forM_ tags $ H.alterM tagMap $ \case
      Just v -> do
        v' <- VPM.grow v 1
        VPM.write v' (VPM.length v) (fromIntegral i)
        pure (Just v')
      Nothing -> Just <$> VPM.replicate 1 (fromIntegral i)
{-# INLINE populateTagMap #-}

buildRelatedPosts :: V.Vector Post -> V.Vector (Int, Post) -> TagMap s -> ST s (V.Vector RelatedPosts)
buildRelatedPosts posts postsIdx tagMap = do
  !sharedTags :: VPM.STVector s Word8 <- VPM.replicate (V.length posts) 0
  !topN :: VPM.STVector s Word64 <- VPM.replicate limitTopN 0

  V.forM postsIdx \(ix, MkPost{_id, tags}) -> do
    collectSharedTags sharedTags tagMap tags
    VPM.write sharedTags ix 0 -- exclude self from related posts
    rankTopN topN sharedTags
    !related <- buildRelated posts topN
    VPM.set topN 0 -- reset
    VPM.set sharedTags 0 -- reset
    pure MkRelatedPosts{_id, tags, related}
{-# INLINE buildRelatedPosts #-}

collectSharedTags :: VPM.STVector s Word8 -> TagMap s -> V.Vector Text -> ST s ()
collectSharedTags sharedTags tagMap tags = do
  V.forM_ tags \tag -> do
    idxs <- H.lookup' tagMap tag
    VPM.forM_ idxs $ VPM.modify sharedTags (+ 1) . fromIntegral
{-# INLINE collectSharedTags #-}

rankTopN :: VPM.STVector s Word64 -> VPM.STVector s Word8 -> ST s ()
rankTopN topN sharedTags = do
  !minTagsST :: STRefU s Word8 <- newSTRefU 0
  VPM.iforM_ sharedTags \jx count -> do
    minTags <- readSTRefU minTagsST
    when (count > minTags) do
      upperBound <- getUpperBound (limitTopN - 2) count topN
      VPM.write topN (upperBound + 1) (word64 (fromIntegral jx, count))
      writeSTRefU minTagsST . unword64Snd =<< VPM.read topN (limitTopN - 1)
 where
  getUpperBound :: Int -> Word8 -> VPM.STVector s Word64 -> ST s Int
  getUpperBound upperBound count topN = do
    if upperBound >= 0
      then do
        w <- VPM.read topN upperBound
        if count > unword64Snd w
          then do
            VPM.write topN (upperBound + 1) w
            getUpperBound (upperBound - 1) count topN
          else pure upperBound
      else pure upperBound
{-# INLINE rankTopN #-}

buildRelated :: V.Vector Post -> VPM.STVector s Word64 -> ST s (V.Vector Post)
buildRelated posts = VPM.foldl (\acc a -> V.snoc acc (posts V.! fromIntegral (unword64Fst a))) V.empty
{-# INLINE buildRelated #-}

word64 :: (Word32, Word8) -> Word64
word64 (w32, w8) = ((fromIntegral w32 :: Word64) `shiftL` 8) .|. (fromIntegral w8 :: Word64)
{-# INLINE word64 #-}

unword64Fst :: Word64 -> Word32
unword64Fst w = fromIntegral (w `shiftR` 8)
{-# INLINE unword64Fst #-}

unword64Snd :: Word64 -> Word8
unword64Snd w = fromIntegral (w .&. 255)
{-# INLINE unword64Snd #-}
