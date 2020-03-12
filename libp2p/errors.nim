type
  LibP2PError* = object of CatchableError

## The following is just some diagnostic
when defined(collect_exceptions):
  import json

  var
      f: File
  doAssert f.open("exceptions.json", fmAppend)

  proc `%`(cstr: cstring): JsonNode = %($cstr)

  globalRaiseHook = proc(e: ref Exception): bool {.gcsafe, locks: 0.} =
    let
      j = %*{
        "name": $e.name,
        "stacktrace": e.getStackTraceEntries()
      }
    f.writeLine(j)
    return true
