{-# LANGUAGE TypeApplications #-}

module Ki.Indef
  ( -- * Context
    Context,
    Ki.Context.background,
    CancelToken,
    Ki.Context.cancelled,
    Ki.Context.cancelledSTM,

    -- * Scope
    Scope,
    scoped,
    wait,
    waitSTM,
    waitFor,
    cancel,

    -- * Thread
    Thread,
    async,
    async_,
    asyncWithUnmask,
    asyncWithUnmask_,
    Thread.await,
    Thread.awaitSTM,
    Thread.awaitFor,
    Thread.kill,

    -- * Exceptions
    Cancelled (..),
    ScopeClosed (..),

    -- * Miscellaneous
    Seconds,
    timeout,
  )
where

import Control.Exception (AsyncException (ThreadKilled), Exception (fromException), SomeException)
import Control.Monad (unless)
import Data.Coerce (coerce)
import Data.Foldable (for_)
import Data.Functor (void)
import qualified Data.Semigroup as Semigroup
import Data.Set (Set)
import qualified Data.Set as Set
import Ki.Indef.Context (CancelToken (..), Cancelled (..), Context)
import qualified Ki.Indef.Context as Ki.Context
import Ki.Indef.Seconds (Seconds)
import Ki.Indef.Thread (AsyncThreadFailed (..), Thread (Thread), timeout)
import qualified Ki.Indef.Thread as Thread
import Ki.Sig (IO, STM, TVar, ThreadId, atomically, forkIO, modifyTVar', myThreadId, newEmptyTMVar, newTVar, newUnique, putTMVar, readTVar, retry, throwIO, throwSTM, throwTo, try, uninterruptibleMask, unsafeUnmask, writeTVar)
import Prelude hiding (IO)

-- import Ki.Internal.Debug

data Scope = Scope
  { context :: Context,
    -- | Whether this scope is closed
    -- Invariant: if closed, no threads are starting
    closedVar :: TVar Bool,
    runningVar :: TVar (Set ThreadId),
    -- | The number of threads that are just about to start
    startingVar :: TVar Int
  }

data ScopeClosed
  = ScopeClosed
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

scoped :: Context -> (Scope -> IO a) -> IO a
scoped parentContext f = do
  uninterruptibleMask \restore -> do
    scope <- new
    result <- restore (try (f scope))
    closeScopeException <- closeScope scope
    case result of
      -- If the callback failed, we don't care if we were thrown an async
      -- exception while closing the scope
      Left exception -> throwIO (Thread.unwrapAsyncThreadFailed exception)
      -- Otherwise, throw that exception (if it exists)
      Right value -> do
        for_ @Maybe closeScopeException throwIO
        pure value
  where
    new :: IO Scope
    new =
      atomically do
        context <- Ki.Context.derive parentContext
        closedVar <- newTVar "closed" False
        runningVar <- newTVar "running" Set.empty
        startingVar <- newTVar "starting" 0
        pure
          Scope
            { context,
              closedVar,
              runningVar,
              startingVar
            }

wait :: Scope -> IO ()
wait =
  atomically . waitSTM

waitSTM :: Scope -> STM ()
waitSTM Scope {runningVar, startingVar} = do
  blockUntilTVar runningVar Set.null
  blockUntilTVar startingVar (== 0)

waitFor :: Scope -> Seconds -> IO ()
waitFor scope seconds =
  timeout seconds (pure <$> waitSTM scope) (pure ())

cancel :: Scope -> IO ()
cancel Scope {context} = do
  token <- newUnique
  atomically (Ki.Context.cancel context (CancelToken token))

-- Close a scope, kill all of the running threads, and return the first async
-- exception delivered to us while doing so, if any.
--
-- Preconditions:
--   * The set of threads doesn't include us
--   * We're uninterruptibly masked
closeScope :: Scope -> IO (Maybe SomeException)
closeScope Scope {closedVar, runningVar, startingVar} = do
  threads <-
    atomically do
      blockUntilTVar startingVar (== 0)
      writeTVar closedVar True
      readTVar runningVar
  exception <- killThreads (Set.toList threads)
  atomically (blockUntilTVar runningVar Set.null)
  pure
    ( coerce
        @(Maybe (Semigroup.First SomeException))
        @(Maybe SomeException)
        exception
    )
  where
    killThreads :: [ThreadId] -> IO (Maybe (Semigroup.First SomeException))
    killThreads =
      loop Nothing
      where
        loop ::
          Maybe (Semigroup.First SomeException) ->
          [ThreadId] ->
          IO (Maybe (Semigroup.First SomeException))
        loop acc = \case
          [] -> pure acc
          threadId : threadIds ->
            -- We unmask because we don't want to deadlock with a thread that is
            -- concurrently trying to throw an exception to us with exceptions
            -- masked.
            try (unsafeUnmask (throwTo threadId ThreadKilled)) >>= \case
              Left exception ->
                loop
                  (acc <> Just (Semigroup.First exception))
                  (threadId : threadIds) -- don't drop thread we didn't kill
              Right () -> loop acc threadIds

async :: Scope -> (Context -> IO a) -> IO (Thread a)
async scope action =
  asyncImpl scope \context restore -> restore (action context)

async_ :: Scope -> (Context -> IO a) -> IO ()
async_ scope action =
  void (async scope action)

asyncWithUnmask ::
  Scope ->
  (Context -> (forall x. IO x -> IO x) -> IO a) ->
  IO (Thread a)
asyncWithUnmask scope action =
  asyncImpl scope \context restore -> restore (action context unsafeUnmask)

asyncWithUnmask_ ::
  Scope ->
  (Context -> (forall x. IO x -> IO x) -> IO a) ->
  IO ()
asyncWithUnmask_ scope f =
  void (asyncWithUnmask scope f)

asyncImpl ::
  Scope ->
  (Context -> (forall x. IO x -> IO x) -> IO a) ->
  IO (Thread a)
asyncImpl Scope {context, closedVar, runningVar, startingVar} action = do
  uninterruptibleMask \restore -> do
    atomically do
      readTVar closedVar >>= \case
        False -> modifyTVar' startingVar (+ 1)
        True -> throwSTM ScopeClosed

    parentThreadId <- myThreadId
    resultVar <- atomically (newEmptyTMVar "result")

    childThreadId <-
      forkIO do
        childThreadId <- myThreadId
        result <- try (action context restore)
        whenLeft result \exception -> do
          whenM
            (shouldPropagateException exception)
            (throwTo parentThreadId (AsyncThreadFailed exception))
        atomically do
          running <- readTVar runningVar
          if Set.member childThreadId running
            then do
              putTMVar resultVar result
              writeTVar runningVar $! Set.delete childThreadId running
            else retry

    atomically do
      modifyTVar' startingVar (subtract 1)
      modifyTVar' runningVar (Set.insert childThreadId)

    pure (Thread childThreadId resultVar)
  where
    shouldPropagateException :: SomeException -> IO Bool
    shouldPropagateException exception =
      case fromException exception of
        Just ThreadKilled -> pure False
        Just _ -> pure True
        Nothing ->
          case fromException exception of
            Just (Cancelled token) -> do
              token' <- Ki.Context.cancelled context
              pure (token' /= Just token)
            Nothing -> pure True

--- Misc. utils

blockUntilTVar :: TVar a -> (a -> Bool) -> STM ()
blockUntilTVar var f = do
  value <- readTVar var
  unless (f value) retry

whenLeft :: Applicative m => Either a b -> (a -> m ()) -> m ()
whenLeft x f =
  case x of
    Left y -> f y
    Right _ -> pure ()

whenM :: Monad m => m Bool -> m () -> m ()
whenM x y =
  x >>= \case
    False -> pure ()
    True -> y