{-# LANGUAGE FunctionalDependencies, RankNTypes, TypeFamilies, TypeOperators #-}
module Control.Effect
( Effectful(..)
-- * Effects
, Eff.Reader
, Eff.State
, Fresh
, throwResumable
-- * Handlers
, run
, runEffect
, raiseHandler
, runReader
, runState
, runFresh
, resume
, runResumableWith
) where

import qualified Control.Monad.Effect as Eff
import Control.Monad.Effect.Fresh
import qualified Control.Monad.Effect.Reader as Eff
import Control.Monad.Effect.Resumable
import qualified Control.Monad.Effect.State as Eff
import Prologue hiding (throwError)

-- | Types wrapping 'Eff.Eff' actions.
--
--   Most instances of 'Effectful' will be derived using @-XGeneralizedNewtypeDeriving@, with these ultimately bottoming out on the instance for 'Eff.Eff' (for which 'raise' and 'lower' are simply the identity). Because of this, types can be nested arbitrarily deeply and still call 'raise'/'lower' just once to get at the (ultimately) underlying 'Eff.Eff'.
class Effectful m where
  -- | Raise an action in 'Eff' into an action in @m@.
  raise :: Eff.Eff effects a -> m effects a
  -- | Lower an action in @m@ into an action in 'Eff'.
  lower :: m effects a -> Eff.Eff effects a

instance Effectful Eff.Eff where
  raise = id
  lower = id


-- Effects

throwResumable :: (Member (Resumable exc) effects, Effectful m) => exc v -> m effects v
throwResumable = raise . throwError


-- Handlers

run :: Effectful m => m '[] a -> a
run = Eff.run . lower

runEffect :: Effectful m => (forall v . effect v -> (v -> m effects a) -> m effects a) -> m (effect ': effects) a -> m effects a
runEffect handler = raiseHandler (Eff.relay pure (\ effect yield -> lower (handler effect (raise . yield))))

-- | Raise a handler on 'Eff.Eff' to a handler on some 'Effectful' @m@.
raiseHandler :: Effectful m => (Eff.Eff effectsA a -> Eff.Eff effectsB b) -> m effectsA a -> m effectsB b
raiseHandler handler = raise . handler . lower

-- | Run a 'Reader' effect in an 'Effectful' context.
runReader :: Effectful m => info -> m (Eff.Reader info ': effects) a -> m effects a
runReader = raiseHandler . flip Eff.runReader

-- | Run a 'State' effect in an 'Effectful' context.
runState :: Effectful m => state -> m (Eff.State state ': effects) a -> m effects (a, state)
runState = raiseHandler . flip Eff.runState

-- | Run a 'Fresh' effect in an 'Effectful' context.
runFresh :: Effectful m => Int -> m (Fresh ': effects) a -> m effects a
runFresh = raiseHandler . flip runFresh'

resume :: (Member (Resumable exc) effects, Effectful m) => m effects a -> (forall v . exc v -> m effects v) -> m effects a
resume m handle = raise (resumeError (lower m) (\yield -> yield <=< lower . handle))

-- | Run a 'Resumable' effect in an 'Effectful' context, using a handler to resume computation.
runResumableWith :: Effectful m => (forall resume . exc resume -> m effects resume) -> m (Resumable exc ': effects) a -> m effects a
runResumableWith handler = raiseHandler (Eff.relay pure (\ (Resumable err) -> (lower (handler err) >>=)))
