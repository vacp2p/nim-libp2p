type
  LibP2PError* = object of CatchableError

## The following is just some diagnostic
import chronicles

globalRaiseHook = proc(e: ref Exception): bool {.gcsafe, locks: 0.} =
  debug "Exception raised!", typename = e.name, loc = e.getStackTraceEntries()[^1]
  trace "Exception trace", stacktrace = e.getStackTrace()
  return true
