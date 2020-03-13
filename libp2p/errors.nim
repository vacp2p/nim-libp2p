type
  LibP2PError* = object of CatchableError

## The following is just some diagnostic
when defined(collect_exceptions):
  import json, sets

  var
      f: File
      entries: HashSet[string]
  doAssert f.open("exceptions.json", fmWrite)

  proc `%`(cstr: cstring): JsonNode = %($cstr)

  globalRaiseHook = proc(e: ref Exception): bool {.gcsafe, locks: 0.} =
    let
      j = %*{
        "name": $e.name,
        "stacktrace": e.getStackTraceEntries()
      }
      jstr = $j
    {.gcsafe.}:
      if not entries.contains(jstr):
        f.writeLine(jstr)
        entries.incl(jstr)
    return true
