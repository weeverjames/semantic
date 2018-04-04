{-# LANGUAGE GADTs, RankNTypes, TypeOperators #-}
module Semantic.Telemetry where

import Control.Monad.Effect.Internal
import Control.Monad.Effect.Reader
import Control.Monad.IO.Class
import Prologue
import Semantic.Log
import Semantic.Queue
import Semantic.Stat

-- | Statting and logging effects.
data Telemetry output where
  WriteStat :: Stat                                  -> Telemetry ()
  WriteLog  :: Level -> String -> [(String, String)] -> Telemetry ()

-- | A task which logs a message at a specific log level to stderr.
writeLog :: Member Telemetry effs => Level -> String -> [(String, String)] -> Eff effs ()
writeLog level message pairs = send (WriteLog level message pairs)

-- | A task which writes a stat.
writeStat :: Member Telemetry effs => Stat -> Eff effs ()
writeStat stat = send (WriteStat stat)

-- | A task which measures and stats the timing of another task.
time :: Members '[Telemetry, IO] effs => String -> [(String, String)] -> Eff effs output -> Eff effs output
time statName tags task = do
  (a, stat) <- withTiming statName tags task
  a <$ writeStat stat


-- | Queues for logging and statting.
data Queues = Queues { logger :: AsyncQueue Message Options, statter :: AsyncQueue Stat StatsClient }

runTelemetry :: Member IO (Reader Queues ': effs) => Eff (Telemetry ': effs) a -> Eff (Reader Queues ': effs) a
runTelemetry = reinterpret (\ t -> case t of
  WriteStat stat -> asks statter >>= \ statter -> liftIO (queue statter stat)
  WriteLog level message pairs -> asks logger >>= \ logger -> queueLogMessage logger level message pairs)

ignoreTelemetry :: Eff (Telemetry ': effs) a -> Eff effs a
ignoreTelemetry = interpret (\ t -> case t of
  WriteStat{} -> pure ()
  WriteLog{}  -> pure ())


reinterpret :: (forall x. effect x -> Eff (newEffect ': effs) x)
            -> Eff (effect ': effs) a
            -> Eff (newEffect ': effs) a
reinterpret handle = loop
  where loop (Val x)  = pure x
        loop (E u' q) = case decompose u' of
            Right eff -> handle eff >>=            q >>> loop
            Left  u   -> E (weaken u) (tsingleton (q >>> loop))
