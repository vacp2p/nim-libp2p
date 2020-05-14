# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import chronos
import chronicles
import macros

# could not figure how to make it with a simple template
# sadly nim needs more love for hygenic templates
# so here goes the macro, its based on the proc/template version
# and uses quote do so it's quite readable

macro checkFutures*[T](futs: seq[Future[T]], exclude: untyped = []): untyped =
  let nexclude = exclude.len
  case nexclude
  of 0:
    quote do:
      for res in `futs`:
        if res.failed:
          let exc = res.readError()
          # We still don't abort but warn
          warn "Something went wrong in a future", error=exc.name
          trace "Exception message", msg=exc.msg
  else:
    quote do:
      for res in `futs`:
        block check:
          if res.failed:
            let exc = res.readError()
            for i in 0..<`nexclude`:
              if exc of `exclude`[i]:
                trace "Ignoring an error (no warning)", error=exc.name, msg=exc.msg
                break check
            # We still don't abort but warn
            warn "Something went wrong in a future", error=exc.name
            trace "Exception message", msg=exc.msg

proc allFuturesThrowing*[T](args: varargs[Future[T]]): Future[void] =
  var futs: seq[Future[T]]
  for fut in args:
    futs &= fut
  proc call() {.async.} =
    var first: ref Exception = nil
    futs = await allFinished(futs)
    for fut in futs:
      if fut.failed:
        let err = fut.readError()
        if err of Defect:
          raise err
        else:
          if isNil(first):
            first = err
    if not isNil(first):
      raise first

  return call()

template tryAndWarn*(message: static[string]; body: untyped): untyped =
  try:
    body
  except CancelledError as exc:
    raise exc # TODO: why catch and re-raise?
  except CatchableError as exc:
    warn "Ignored an error", name = exc.name, msg = message, exc = exc.msg
