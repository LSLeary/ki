module Ki.Experimental.Pusher
  ( pusher,
    pusher2,
  )
where

import Control.Concurrent.STM
import Control.Monad
import qualified Ki.Fork
import Ki.Prelude
import Ki.Scope (Scope)
import qualified Ki.Scope

data S a
  = Closed !(Maybe a) -- last value, if full when closed
  | Empty
  | Full !a !(TMVar ())

pusher :: Scope -> ((a -> IO ()) -> IO ()) -> IO (STM (Maybe a))
pusher scope action = do
  resultVar <- newTVarIO Empty

  let close :: IO ()
      close =
        atomically do
          readTVar resultVar >>= \case
            Closed _ -> error "closed"
            Empty -> writeTVar resultVar $! Closed Nothing
            Full value _ -> writeTVar resultVar $! Closed (Just value)

  let produce :: IO ()
      produce =
        action \value -> do
          tookVar <- newEmptyTMVarIO
          atomicallyIO do
            readTVar resultVar >>= \case
              Closed _ -> error "closed"
              Empty -> do
                writeTVar resultVar $! Full value tookVar
                pure (atomicallyIO (pure <$> readTMVar tookVar <|> Ki.Scope.cancelledSTM scope))
              Full _ _ -> Ki.Scope.cancelledSTM scope

  uninterruptibleMask \_ -> do
    Ki.Fork.forkWithUnmask scope \unmask -> do
      unmask produce `onException` close
      close

  pure do
    readTVar resultVar >>= \case
      Closed Nothing -> pure Nothing
      Closed value -> do
        writeTVar resultVar $! Closed Nothing
        pure value
      Empty -> retry
      Full value tookVar -> do
        writeTVar resultVar Empty
        putTMVar tookVar ()
        pure (Just value)

data S2 a
  = S2 !a !(TVar Bool)

pusher2 :: Scope -> ((a -> IO ()) -> IO ()) -> IO (STM (Maybe a))
pusher2 scope action = do
  closedVar <- newTVarIO False
  queue <- newTQueueIO

  let close :: IO ()
      close =
        atomically (writeTVar closedVar True)

  let produce :: IO ()
      produce =
        action \value -> do
          tookVar <- newTVarIO False
          atomicallyIO do
            writeTQueue queue (S2 value tookVar)
            pure (atomicallyIO (pure <$> (readTVar tookVar >>= check) <|> Ki.Scope.cancelledSTM scope))

  uninterruptibleMask \_ -> do
    Ki.Fork.forkWithUnmask scope \unmask -> do
      unmask produce `onException` close
      close

  pure do
    ( do
        S2 value tookVar <- readTQueue queue
        writeTVar tookVar True $> Just value
      )
      <|> ((readTVar closedVar >>= check) $> Nothing)

{-
_testProducer :: IO ()
_testProducer = do
  lock <- newMVar ()
  global do
    scoped \scope1 -> do
      recv <- producer scope1 go
      let r = atomically recv >>= withMVar lock . const . print
      scoped \scope2 -> do
        fork scope2 (replicateM_ 4 r)
        fork scope2 (replicateM_ 5 r)
        fork scope2 (replicateM_ 6 r)
        wait scope2
      cancel scope1
      wait scope1
  where
    go :: Context => (Int -> IO ()) -> IO ()
    go send = do
      scoped \scope -> do
        fork scope (loop 1)
        fork scope (loop 10)
        fork scope (loop 100)
        wait scope
      where
        loop :: Int -> IO ()
        loop n = do
          send n
          sleep 0.2
          loop (n + 1)
-}
