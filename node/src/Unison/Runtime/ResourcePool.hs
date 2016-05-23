module Unison.Runtime.ResourcePool where

import Data.Maybe (fromMaybe)
import Control.Applicative
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM.TMVar (TMVar)
import Data.Functor
import Data.Time (UTCTime, getCurrentTime, addUTCTime, diffUTCTime)
import qualified Control.Concurrent as CC
import qualified Control.Concurrent.MVar as MVar
import qualified Control.Concurrent.Map as M
import qualified Control.Concurrent.STM.TMVar as TMVar
import qualified Control.Concurrent.STM.TQueue as TQ
import qualified Control.Monad.STM as STM
import qualified Data.Hashable as H
import qualified Data.IORef as IORef

-- | `acquire` returns the resource, and the cleanup action ("finalizer") for that resource
data ResourcePool p r = ResourcePool { acquire :: p -> IO (r, IO ()) }

{-
The `ResourcePool p r` is backed by a mutable `Map p (RecycleQueue r)`.
The `RecycleQueue r` is a queue of resources that have been logically
'released' but are available for recycling. After their expiration, a
separate 'reaper thread' will remove them from the queue.

The basic logic for `acquire` is:

1.  Try to obtain a recycled resource for the requested key.
2a. If that succeeds, the resource is taken from the recycle queue,
    preventing multiple threads from accessing the same resource.
2b. If that fails, acquire a fresh resource.
3.  The returned finalizer just adds an entry to the recycle queue,
    for the recycled or newly acquired resource, with a new expiration
    based a delta plus the time the finalizer is called.

Thus, multiple resources may be acquired for the same key simultaneously,
and these resources will be recycled if another acquisition occurs before
expiration.
-}

data Cache p r =
  Cache { count :: IORef.IORef PoolSize
        , lock :: MVar () -- used as a lock when allocating new RecycleQueue
        , recycleQueues :: M.Map p (RecycleQueue r) }

type RecycleQueue r = TQ.TQueue (TMVar r, CC.ThreadId, IO ())
type MaxPoolSize = Int
type Seconds = Int
type PoolSize = Int

incrementCount :: Cache p r -> IO ()
incrementCount c = IORef.atomicModifyIORef' (count c) (\a -> (a+1, ()))

decrementCount :: Cache p r -> IO ()
decrementCount c = IORef.atomicModifyIORef' (count c) (\a -> (a-1, ()))

getCount :: Cache p r -> IO Int
getCount c = IORef.readIORef (count c)

lookupQueue :: (Ord p, H.Hashable p) => p -> Cache p r -> IO (RecycleQueue r)
lookupQueue p (Cache _ lock m) = do
  q <- M.lookup p m
  case q of
    Nothing -> do
      MVar.takeMVar lock
      q <- STM.atomically TQ.newTQueue
      M.insert p q m
      MVar.putMVar lock ()
      pure q
    Just q -> pure q

recycleOrReacquire :: Show p => (p -> IO r) -> (r -> IO ()) -> Cache p q -> RecycleQueue r -> p -> IO (r, IO ())
recycleOrReacquire acquire release cache q p = do
  avail <- STM.atomically $ TQ.tryReadTQueue q
  case avail of
    Nothing -> do
      -- putStrLn $ "nothing available for " ++ show p ++ ", allocating fresh"
      r <- acquire p
      r' <- STM.atomically $ TMVar.newTMVar (Just r)
      pure (r, release r)
    Just (r, id, release') -> do
      decrementCount cache
      r' <- STM.atomically $ TMVar.tryTakeTMVar r
      case r' of
        Nothing -> recycleOrReacquire acquire release cache q p
        Just r -> do
          -- putStrLn $ "got recycled resource for " ++ show p
          CC.killThread id
          pure (r, release')

_acquire :: (Ord p, H.Hashable p, Show p)
         => (p -> IO r)
         -> (r -> IO ())
         -> Cache p r
         -> Seconds
         -> MaxPoolSize
         -> p
         -> IO (r, IO ())
_acquire acquire release cache waitInSeconds maxPoolSize p = do
  q <- lookupQueue p cache
  (r, release) <- recycleOrReacquire acquire release cache q p
  delayedRelease <- pure $ do
    currentSize <- IORef.readIORef (count cache)
    case currentSize of
      n | n >= maxPoolSize -> release
        | otherwise        -> do
          empty <- STM.atomically (TQ.isEmptyTQueue q)
          -- putStrLn $ "enqueueing for " ++ show p ++ " " ++ show empty
          incrementCount cache
          r' <- STM.atomically (TMVar.newTMVar r)
          id <- CC.forkIO $ do
            CC.threadDelay (1000000 * waitInSeconds)
            msg <- STM.atomically $ TMVar.tryTakeTMVar r'
            case msg of Nothing -> pure (); Just _ -> release
          STM.atomically $ TQ.writeTQueue q (r', id, release)
  pure (r, delayedRelease)

make :: (Ord p, H.Hashable p, Show p)
     => Seconds -> MaxPoolSize -> (p -> IO r) -> (r -> IO ()) -> IO (ResourcePool p r)
make waitInSeconds maxPoolSize acquire release = do
  ps <- IORef.newIORef 0
  lock <- MVar.newMVar ()
  recycleQueues <- M.empty
  let cache = Cache ps lock recycleQueues
  pure $ ResourcePool { acquire = _acquire acquire release cache waitInSeconds maxPoolSize }
