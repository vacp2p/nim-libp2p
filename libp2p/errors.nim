# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import chronos
import chronicles
import macros

type
  # Base exception type for libp2p
  LPError* = object of CatchableError

func toException*(e: cstring): ref LPError =
  (ref LPError)(msg: $e)

func toException*(e: string): ref LPError =
  (ref LPError)(msg: e)

# TODO: could not figure how to make it with a simple template
# sadly nim needs more love for hygienic templates
# so here goes the macro, its based on the proc/template version
# and uses quote do so it's quite readable
# TODO https://github.com/nim-lang/Nim/issues/22936
macro checkFutures*[F](futs: seq[F], exclude: untyped = []): untyped =
  let nexclude = exclude.len
  case nexclude
  of 0:
    quote:
      for res in `futs`:
        if res.failed:
          let exc = res.readError()
          # We still don't abort but warn
          debug "A future has failed, enable trace logging for details",
            error = exc.name
          trace "Exception message", exc = exc.msg, stack = getStackTrace()
  else:
    quote:
      for res in `futs`:
        block check:
          if res.failed:
            let exc = res.readError()
            for i in 0 ..< `nexclude`:
              if exc of `exclude`[i]:
                trace "A future has failed", error = exc.name, exc = exc.msg
                break check
            # We still don't abort but warn
            debug "A future has failed, enable trace logging for details",
              error = exc.name
            trace "Exception details", exc = exc.msg
