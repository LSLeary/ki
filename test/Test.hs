{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Concurrent.Classy hiding (fork, forkWithUnmask, wait)
import Control.Exception
  ( AsyncException (ThreadKilled),
    Exception,
    MaskingState (..),
    SomeException,
    pattern ErrorCall,
  )
import Control.Monad
import Data.Function
import Data.Functor
import Data.Maybe
import DejaFuTestUtils
import Ki.Implicit
import Prelude

main :: IO ()
main = do
  test "background context isn't cancelled" (returns False) (isJust <$> cancelled)

  test "new scope doesn't start out cancelled" (returns False) (scoped \_ -> isJust <$> cancelled)

  test "`cancel` observable by scope's `cancelled`" (returns True) do
    scoped \scope -> do
      cancel scope
      isJust <$> cancelled

  test "`cancel` observable by inner scope's `cancelled`" (returns True) do
    scoped \scope1 -> do
      scoped \_ -> do
        cancel scope1
        isJust <$> cancelled

  test "`cancel` observable by child's `cancelled`" (returns True) do
    scoped \scope1 -> do
      thread <-
        async scope1 do
          cancel scope1
          isJust <$> cancelled
      await' thread

  test "`cancel` observable by child's inner `cancelled`" (returns True) do
    scoped \scope1 -> do
      thread <-
        async scope1 do
          scoped \_ -> do
            cancel scope1
            isJust <$> cancelled
      await' thread

  test "`cancel` observable by grandchild's `cancelled`" (returns True) do
    scoped \scope1 -> do
      thread1 <-
        async scope1 do
          scoped \scope2 -> do
            thread2 <-
              async scope2 do
                cancel scope1
                isJust <$> cancelled
            await' thread2
      await' thread1

  test "inner scope inherits cancellation" (returns True) do
    scoped \scope1 -> do
      cancel scope1
      scoped \_ -> isJust <$> cancelled

  test "inner thread inherits cancellation" (returns True) do
    scoped \scope -> do
      cancel scope
      thread <- async scope cancelled
      isJust <$> await' thread

  todo "cancelled child context removes parent's ref to it"

  test "`wait` succeeds when no threads are alive" (returns ()) (scoped wait)

  test "`wait` waits for `fork`" (returns True) do
    ref <- newIORef False
    scoped \scope -> do
      fork_ scope (writeIORef ref True)
      wait scope
    readIORef ref

  test "`wait` waits for `async`" (returns True) do
    ref <- newIORef False
    scoped \scope -> do
      _ <- async scope (writeIORef ref True)
      wait scope
    readIORef ref

  test "`waitFor` sometimes waits for a thread, sometimes kills it" (nondeterministic [Right False, Right True]) do
    ref <- newIORef False
    scoped \scope -> do
      fork_ scope (writeIORef ref True)
      waitFor scope 1
    readIORef ref

  test "using a closed scope throws ErrorCall" (throws (ErrorCall "ki: scope closed")) do
    scope <- scoped pure
    fork_ scope (pure ())

  test "`await` waits" (returns True) do
    scoped \scope -> do
      thread <- async scope (pure ())
      isRight <$> await thread

  test "`await` waits for exception" (returns True) do
    scoped \scope -> do
      thread <- async scope (throw A)
      isLeft <$> await thread

  test "thread can be awaited after its scope closes" (returns True) do
    thread <- scoped \scope -> do
      thread <- async scope (pure ())
      wait scope
      pure thread
    isRight <$> await thread

  -- test "thread can be killed" do
  --   returns () do
  --     scoped \scope -> do
  --       thread <- async scope block
  --       kill thread

  -- test "thread can be killed after it's finished" do
  --   returns () do
  --     scoped \scope -> do
  --       thread <- async scope (pure ())
  --       _ <- await thread
  --       kill thread

  test "`fork` forks a background thread" (returns True) do
    scoped \scope -> do
      var <- newEmptyMVar
      fork_ scope (myThreadId >>= putMVar var)
      (/=) <$> myThreadId <*> takeMVar var

  test "`fork`ed thread inherits masking state" (returns (Unmasked, MaskedInterruptible, MaskedUninterruptible)) do
    scoped \scope -> do
      var1 <- newEmptyMVar
      var2 <- newEmptyMVar
      var3 <- newEmptyMVar
      fork_ scope (getMaskingState >>= putMVar var1)
      mask_ (fork_ scope (getMaskingState >>= putMVar var2))
      uninterruptibleMask_ (fork_ scope (getMaskingState >>= putMVar var3))
      (,,) <$> takeMVar var1 <*> takeMVar var2 <*> takeMVar var3

  test "`fork` propagates sync exceptions to parent" (throws A) do
    scoped \scope -> do
      fork_ scope (throw A)
      wait scope

  {- seems like a dejafu bug
  test "`fork` propagates async exceptions to parent" (throws ThreadKilled) do
    scoped \scope -> do
      var <- newEmptyMVar
      fork_ scope do
        myThreadId >>= putMVar var
        block
      takeMVar var >>= killThread
      block
  -}

  test "`async` doesn't propagate exceptions" (returns ()) (scoped \scope -> void (async scope (throw A)))

  test "`await` returns Left if thread throws" (returns True) do
    scoped \scope -> do
      thread <- async scope (throw A)
      isLeft <$> await thread

  test "`async` inherits masking state" (returns (Unmasked, MaskedInterruptible, MaskedUninterruptible)) do
    scoped \scope -> do
      thread1 <- async scope getMaskingState
      thread2 <- mask_ (async scope getMaskingState)
      thread3 <- uninterruptibleMask_ (async scope getMaskingState)
      (,,)
        <$> (either throw pure =<< await thread1)
        <*> (either throw pure =<< await thread2)
        <*> (either throw pure =<< await thread3)

  test "`asyncWithUnmask` inherits masking state" (returns (Unmasked, MaskedInterruptible, MaskedUninterruptible)) do
    scoped \scope -> do
      thread1 <- asyncWithUnmask scope \_ -> getMaskingState
      thread2 <- mask_ (asyncWithUnmask scope \_ -> getMaskingState)
      thread3 <- uninterruptibleMask_ (asyncWithUnmask scope \_ -> getMaskingState)
      (,,)
        <$> (either throw pure =<< await thread1)
        <*> (either throw pure =<< await thread2)
        <*> (either throw pure =<< await thread3)

  test "`asyncWithUnmask` provides an unmasking function" (returns Unmasked) do
    scoped \scope -> do
      thread <- mask_ (asyncWithUnmask scope \unmask -> unmask getMaskingState)
      either throw pure =<< await thread

  todo "`forkWithUnmask` inherits masking state"

  todo "`forkWithUnmask` provides an unmasking function"

  todo "`scoped` wraps async exceptions it throws in SyncException"

  test "`scoped` kills threads when it throws" (returns ()) do
    ignoring @A do
      scoped \scope -> do
        var <- newEmptyMVar
        uninterruptibleMask_ do
          forkWithUnmask_ scope \unmask -> do
            putMVar var ()
            unmask block
        takeMVar var
        void (throw A)

  test "`scoped` kills threads when `fork` throws" (returns ()) do
    ignoring @A do
      scoped \scope -> do
        fork_ scope block
        fork_ scope (void (throw A))
        wait scope

  test "thread waiting on its own scope deadlocks" deadlocks do
    scoped \scope -> do
      fork_ scope (wait scope)
      wait scope

  test "thread waiting on its own scope allows async exceptions" (returns ()) do
    scoped \scope -> fork_ scope (wait scope)

  test "`fork` doesn't propagate `CancelToken`" (returns ()) do
    scoped \scope -> do
      cancel scope
      fork_ scope do
        cancelled >>= \case
          Nothing -> throw A
          Just cancelToken -> throw cancelToken
      wait scope

data A
  = A
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

await' :: Thread (Either SomeException a) -> P a
await' =
  await >=> either throw pure

isLeft :: Either a b -> Bool
isLeft =
  either (const True) (const False)

isRight :: Either a b -> Bool
isRight =
  either (const False) (const True)

-- finally :: P a -> P b -> P a
-- finally action after =
--   mask \restore -> do
--     result <- restore action `onException` after
--     _ <- after
--     pure result

-- onException :: P a -> P b -> P a
-- onException action cleanup =
--   catch @_ @SomeException action \ex -> do
--     _ <- cleanup
--     throw ex
