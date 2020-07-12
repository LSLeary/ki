module Ki.Prelude
  ( atomicallyIO,
    whenLeft,
    whenM,
    module X,
  )
where

import Control.Applicative as X ((<|>), optional)
import Control.Exception as X (Exception, SomeException)
import Control.Monad as X (join, unless)
import Data.Coerce as X (coerce)
import Data.Foldable as X (for_)
import Data.Function as X (fix)
import Data.Functor as X (($>), (<&>), void)
import Data.IntMap.Strict as X (IntMap)
import Data.Map.Strict as X (Map)
import Data.Maybe as X (fromMaybe)
import Data.Set as X (Set)
import Data.Word as X (Word32)
import GHC.Generics as X (Generic)
import Ki.Concurrency as X
import Prelude as X hiding (IO)

atomicallyIO :: STM (IO a) -> IO a
atomicallyIO =
  join . atomically

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
