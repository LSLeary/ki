module Ki.Scope
  ( Scope,
    scoped,
    wait,
    waitFor,
    waitSTM,
    --
    Thread,
    Unmask,
    async,
    asyncWithUnmask,
    await,
    awaitFor,
    awaitSTM,
    fork,
    fork_,
    forkWithUnmask,
    forkWithUnmask_,
  )
where

import Control.Exception
  ( BlockedIndefinitelyOnSTM (..),
    Exception (fromException, toException),
    SomeAsyncException,
    asyncExceptionFromException,
    asyncExceptionToException,
    catch,
    pattern ErrorCall,
  )
import Control.Monad.IO.Unlift (MonadUnliftIO (withRunInIO))
import Data.Function (on)
import qualified Data.IntMap.Lazy as IntMap
import Data.Maybe (isJust)
import qualified Data.Monoid as Monoid
import Data.Ord (comparing)
import Ki.Counter
import Ki.Duration (Duration)
import Ki.Prelude
import Ki.Timeout

------------------------------------------------------------------------------------------------------------------------
-- Scope

-- | A __scope__ delimits the lifetime of all __threads__ created within it.
data Scope = Scope
  { -- | The set of child threads that are currently running, each keyed by a monotonically increasing int.
    childrenVar :: {-# UNPACK #-} !(TVar (IntMap ThreadId)),
    -- | The counter that holds the (int) key to use for the next child thread.
    nextChildIdCounter :: {-# UNPACK #-} !Counter,
    -- | The number of child threads that are guaranteed to be about to start, in the sense that only the GHC scheduler
    -- can continue to delay; no async exception can strike here and prevent one of these threads from starting.
    --
    -- Sentinel value: -1 means the scope is closed.
    startingVar :: {-# UNPACK #-} !(TVar Int)
  }

-- | Exception thrown by a parent __thread__ to its children when its __scope__ is closing.
data ScopeClosing
  = ScopeClosing
  deriving stock (Eq, Show)

instance Exception ScopeClosing where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

lowLevelFork :: Scope -> (Unmask IO -> IO a) -> (Either SomeException a -> IO ()) -> IO ThreadId
lowLevelFork Scope {childrenVar, nextChildIdCounter, startingVar} action k =
  uninterruptibleMask \restore -> do
    -- Record the thread as being about to start.
    atomically do
      readTVar startingVar >>= \case
        -1 -> throwSTM (ErrorCall "ki: scope closed")
        n -> writeTVar startingVar $! n + 1

    -- Grab a unique id for this child.
    childId <- incrCounter nextChildIdCounter

    childThreadId <-
      forkIO do
        result <- try (action restore)
        -- FIXME should this go after the `k result` below?
        -- Perhaps, because we've deleted from childrenVar but are still running for a bit... :thinking:
        --
        -- Common case: we alter the map at key `childId`, setting `Just childThreadId` to `Nothing` (unrecording the
        -- child as running)
        --
        -- Uncommon case: we alter the map at key `childId`, but it's still `Nothing` (wow!) indicating that we finished
        -- before the parent was scheduled to record the child as running, so delicately place a "certificate of quick
        -- death" `Just undefined` in there.
        atomically (modifyTVar' childrenVar (IntMap.alter (maybe (Just undefined) (const Nothing)) childId))
        -- Perform the internal callback (this is where we decide to propagate the exception and whatnot)
        k result

    -- Record the child as having started
    atomically do
      modifyTVar' startingVar \n -> n -1
      -- Common case: we alter the map at key `childId`, setting `Nothing` to `Just childThreadId` (recording the child
      -- as running)
      --
      -- Uncommon case: we alter the map at key `childId`, but it's already `Just undefined` (wow!) indicating that the
      -- child already finished, so no need to record it as having started - set to `Nothing`, though, to delete this
      -- now-unneeded `Just undefined` "certificate of quick death".
      modifyTVar' childrenVar (IntMap.alter (maybe (Just childThreadId) (const Nothing)) childId)

    pure childThreadId

-- | Open a __scope__, perform an action with it, then close the __scope__.
--
-- When the __scope__ is closed, all remaining __threads__ created within it are thrown an asynchronous exception in the
-- order they were created, and FIXME we block until they all terminate.
--
-- ==== __Examples__
--
-- @
-- 'Ki.scoped' \\scope -> do
--   'Ki.fork_' scope worker1
--   'Ki.fork_' scope worker2
--   'Ki.wait' scope
-- @
scoped :: MonadUnliftIO m => (Scope -> m a) -> m a
scoped action =
  withRunInIO \unlift -> scopedIO (unlift . action)
{-# INLINE scoped #-}
{-# SPECIALIZE scoped :: (Scope -> IO a) -> IO a #-}

scopedIO :: (Scope -> IO a) -> IO a
scopedIO f = do
  childrenVar <- newTVarIO IntMap.empty
  nextChildIdCounter <- newCounter
  startingVar <- newTVarIO 0
  let scope = Scope {childrenVar, nextChildIdCounter, startingVar}

  uninterruptibleMask \restore -> do
    result <- try (restore (f scope))

    children <-
      atomically do
        -- Block until we haven't committed to starting any threads. Without this, we may create a thread concurrently
        -- with closing its scope, and not grab its thread id to throw an exception to.
        blockUntil0 startingVar
        -- Write the sentinel value indicating that this scope is closed, and it is an error to try to create a thread
        -- within it.
        writeTVar startingVar (-1)
        -- Return the list of currently-running children to kill. Some of them may have *just* started (e.g. if we
        -- initially retried in `blockUntil0` above). That's fine - kill them all!
        readTVar childrenVar

    -- Deliver an async exception to every child. While doing so, we may get hit by an async exception ourselves, which
    -- we don't want to just ignore. (Actually, we may have been hit by an arbitrary number of async exceptions,
    -- but it's unclear what we would do with such a list, so we only remember the first one, and ignore the others).
    firstExceptionReceivedWhileKillingChildren <- killThreads (IntMap.elems children)

    -- Block until all children have terminated; this relies on children respecting the async exception, which they
    -- must, for correctness. Otherwise, a thread could indeed outlive the scope in which it's created, which is
    -- definitely not structured concurrency!
    atomically (blockUntilEmpty childrenVar)

    -- If the callback failed, we don't care if we were thrown an async exception while closing the scope. Otherwise,
    -- throw that exception (if it exists).
    case result of
      Left exception -> throw exception
      Right value -> do
        whenJust firstExceptionReceivedWhileKillingChildren throw
        pure value
  where
    -- If applicable, unwrap the 'ThreadFailed' (assumed to have come from one of our children).
    throw :: SomeException -> IO a
    throw exception =
      case fromException exception of
        Just (ThreadFailed threadFailedException) -> throwIO threadFailedException
        Nothing -> throwIO exception

    -- In the order they were created, throw at least one ScopeClosing exception to each of the given threads.
    --
    -- This function must be called with asynchronous exceptions masked, but we unmask in order to throw each
    -- ScopeClosing in order to avoid a deadlock with that child thread, in case it is trying to propagate an exception
    -- to us at the same time, which which *it* does with asynchronous exceptions masked, so its failure does not go
    -- unnoticed.
    --
    -- It's possible, therefore, that we get hit by an asynchronous exception just *before* or just *after* throwing
    -- each ScopeClosing. If this occurs, we do not remove the ThreadId from the list of ThreadIds to which we will
    -- throw a ScopeClosing, in case we got hit by some asynchronous exception *before* delivering the ScopeClosing.
    -- This is why each child thread will ultimately receive *at least one* ScopeClosing exception.
    --
    -- As far as what to do with the asynchronous exceptions that are delivered to us - because there's no convenient or
    -- ergonomic way to throw or catch a "multi-exception", we only remember the first one, to re-throw after all of the
    -- threads we are trying to kill here actually terminate.
    killThreads :: [ThreadId] -> IO (Maybe SomeException)
    killThreads =
      let loop :: Monoid.First SomeException -> [ThreadId] -> IO (Maybe SomeException)
          loop acc = \case
            [] -> pure (Monoid.getFirst acc)
            threadId : threadIds ->
              try (unsafeUnmask (throwTo threadId ScopeClosing)) >>= \case
                -- intentionally don't drop threadId, since we don't know if we delivered it an exception or not
                Left exception -> loop (acc <> Monoid.First (Just exception)) (threadId : threadIds)
                Right () -> loop acc threadIds
       in loop mempty

-- | Wait until all __threads__ created within a __scope__ terminate.
wait :: MonadIO m => Scope -> m ()
wait =
  liftIO . atomically . waitSTM
{-# INLINE wait #-}
{-# SPECIALIZE wait :: Scope -> IO () #-}

-- | Variant of 'Ki.wait' that waits for up to the given duration.
waitFor :: MonadIO m => Scope -> Duration -> m ()
waitFor scope duration =
  liftIO (timeoutSTM duration (pure <$> waitSTM scope) (pure ()))
{-# INLINE waitFor #-}
{-# SPECIALIZE waitFor :: Scope -> Duration -> IO () #-}

-- | @STM@ variant of 'Ki.wait'.
waitSTM :: Scope -> STM ()
waitSTM Scope {childrenVar, startingVar} = do
  blockUntilEmpty childrenVar
  blockUntil0 startingVar
{-# INLINE waitSTM #-}

-- | Block until an @IntMap@ becomes empty.
blockUntilEmpty :: TVar (IntMap a) -> STM ()
blockUntilEmpty var = do
  x <- readTVar var
  when (not (IntMap.null x)) retry

-- | Block until a @TVar@ becomes 0.
blockUntil0 :: TVar Int -> STM ()
blockUntil0 var =
  readTVar var >>= \case
    0 -> pure ()
    _ -> retry

------------------------------------------------------------------------------------------------------------------------
-- Thread

-- | A running __thread__.
data Thread a = Thread
  { await_ :: !(STM a),
    ident :: {-# UNPACK #-} !ThreadId
  }
  deriving stock (Functor)

instance Eq (Thread a) where
  (==) =
    (==) `on` ident

instance Ord (Thread a) where
  compare =
    comparing ident

-- | Exception thrown by a child __thread__ to its parent, if it fails unexpectedly.
newtype ThreadFailed
  = ThreadFailed SomeException
  deriving stock (Show)

instance Exception ThreadFailed where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | A function that unmasks asynchronous exceptions.
type Unmask m =
  forall x. m x -> m x

-- | Create a child __thread__ within a __scope__.
async :: MonadUnliftIO m => Scope -> m a -> m (Thread (Either SomeException a))
async scope action =
  withRunInIO \unlift ->
    asyncWithRestore scope \restore ->
      restore (unlift action)
{-# INLINE async #-}
{-# SPECIALIZE async :: Scope -> IO a -> IO (Thread (Either SomeException a)) #-}

-- | Variant of 'Ki.async' that provides the __thread__ a function that unmasks asynchronous exceptions.
asyncWithUnmask ::
  MonadUnliftIO m =>
  Scope ->
  (Unmask m -> m a) ->
  m (Thread (Either SomeException a))
asyncWithUnmask scope action =
  withRunInIO \unlift ->
    asyncWithRestore scope \restore ->
      restore (unlift (action (liftIO . unsafeUnmask . unlift)))
{-# INLINE asyncWithUnmask #-}
{-# SPECIALIZE asyncWithUnmask ::
  Scope ->
  (Unmask IO -> IO a) ->
  IO (Thread (Either SomeException a))
  #-}

asyncWithRestore :: Scope -> (Unmask IO -> IO a) -> IO (Thread (Either SomeException a))
asyncWithRestore scope action = do
  parentThreadId <- myThreadId
  resultVar <- newEmptyTMVarIO
  ident <-
    lowLevelFork scope action \result -> do
      case result of
        Left exception -> maybePropagateException parentThreadId exception isAsyncException
        Right _ -> pure ()
      putTMVarIO resultVar result -- even put async exceptions that we propagated
  pure
    Thread
      { await_ = readTMVar resultVar,
        ident
      }
  where
    isAsyncException :: SomeException -> Bool
    isAsyncException =
      isJust . fromException @SomeAsyncException

-- | Wait for a __thread__ to terminate.
await :: MonadIO m => Thread a -> m a
await thread =
  -- If *they* are deadlocked, we will *both* will be delivered a wakeup from the RTS. We want to shrug this exception
  -- off, because afterwards they'll have put to the result var. But don't shield indefinitely, once will cover this use
  -- case and prevent any accidental infinite loops.
  liftIO (go `catch` \BlockedIndefinitelyOnSTM -> go)
  where
    go =
      atomically (await_ thread)
{-# INLINE await #-}
{-# SPECIALIZE await :: Thread a -> IO a #-}

-- | Variant of 'Ki.await' that gives up after the given duration.
awaitFor :: MonadIO m => Thread a -> Duration -> m (Maybe a)
awaitFor thread duration =
  liftIO (timeoutSTM duration (pure . Just <$> await_ thread) (pure Nothing))
{-# INLINE awaitFor #-}
{-# SPECIALIZE awaitFor :: Thread a -> Duration -> IO (Maybe a) #-}

-- | @STM@ variant of 'Ki.await'.
awaitSTM :: Thread a -> STM a
awaitSTM =
  await_

-- | Create a child __thread__ within a __scope__.
--
-- If the child __thread__ throws an exception, the exception is immediately propagated to its parent __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork :: MonadUnliftIO m => Scope -> m a -> m (Thread a)
fork scope action =
  withRunInIO \unlift ->
    forkWithRestore scope \restore ->
      restore (unlift action)
{-# INLINE fork #-}
{-# SPECIALIZE fork :: Scope -> IO a -> IO (Thread a) #-}

-- | Variant of 'Ki.fork' that does not return a handle to the child __thread__.
--
-- If the child __thread__ throws an exception, the exception is immediately propagated to its parent __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork_ :: MonadUnliftIO m => Scope -> m () -> m ()
fork_ scope action =
  withRunInIO \unlift ->
    forkWithRestore_ scope \restore ->
      restore (unlift action)
{-# INLINE fork_ #-}
{-# SPECIALIZE fork_ :: Scope -> IO () -> IO () #-}

-- | Variant of 'Ki.fork' that provides the child __thread__ a function that unmasks asynchronous exceptions.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask :: MonadUnliftIO m => Scope -> (Unmask m -> m a) -> m (Thread a)
forkWithUnmask scope action =
  withRunInIO \unlift ->
    forkWithRestore scope \restore ->
      restore (unlift (action (liftIO . unsafeUnmask . unlift)))
{-# INLINE forkWithUnmask #-}
{-# SPECIALIZE forkWithUnmask ::
  Scope ->
  (Unmask IO -> IO a) ->
  IO (Thread a)
  #-}

-- | Variant of 'Ki.forkWithUnmask' that does not return a handle to the child __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask_ :: MonadUnliftIO m => Scope -> (Unmask m -> m ()) -> m ()
forkWithUnmask_ scope action =
  withRunInIO \unlift ->
    forkWithRestore_ scope \restore ->
      restore (unlift (action (liftIO . unsafeUnmask . unlift)))
{-# INLINE forkWithUnmask_ #-}
{-# SPECIALIZE forkWithUnmask_ ::
  Scope ->
  (Unmask IO -> IO ()) ->
  IO ()
  #-}

forkWithRestore :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread a)
forkWithRestore scope action = do
  parentThreadId <- myThreadId
  resultVar <- newEmptyTMVarIO
  ident <-
    lowLevelFork scope action \result -> do
      case result of
        Left exception -> maybePropagateException parentThreadId exception (const True)
        Right _ -> pure ()
      -- even put async exceptions that we propagated
      -- this isn't totally ideal because a caller awaiting this thread would not be able to distinguish between async
      -- exceptions delivered to this thread, or itself
      putTMVarIO resultVar result
  pure
    Thread
      { await_ = readTMVar resultVar >>= either throwSTM pure,
        ident
      }

forkWithRestore_ :: Scope -> (Unmask IO -> IO ()) -> IO ()
forkWithRestore_ scope action = do
  parentThreadId <- myThreadId
  _childThreadId <-
    lowLevelFork scope action \case
      Left exception -> maybePropagateException parentThreadId exception (const True)
      Right () -> pure ()
  pure ()

maybePropagateException :: ThreadId -> SomeException -> (SomeException -> Bool) -> IO ()
maybePropagateException parentThreadId exception should =
  when shouldPropagateException (throwTo parentThreadId (ThreadFailed exception))
  where
    shouldPropagateException :: Bool
    shouldPropagateException
      -- Trust without verifying that any 'ScopeClosed' exception, which is not exported by this module, was indeed
      -- thrown to a thread by this library, and not randomly caught by a user and propagated to some thread.
      | Just ScopeClosing <- fromException exception = False
      | otherwise = should exception