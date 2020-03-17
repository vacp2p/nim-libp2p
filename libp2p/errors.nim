import options # UnpackError
export options
# standard errors:
# ValueError, IndexError, Exception, FieldError, KeyError, AccessViolationError, IOError, OSError, AssertionError, LibraryError, UnpackError, DivByZeroError, ReraiseError, OverflowError, RangeError, ObjectConversionError, ResourceExhaustedError

type
  LibP2PError* = object of CatchableError
  StdLibError* =
    ValueError |
    IndexError |
    Exception |
    FieldError |
    KeyError |
    AccessViolationError |
    IOError |
    # EParseError | # some doc rst error
    OSError |
    # ReplyError | # smtp error, we got smtp in std? yay?
    # FutureError | # we dont use this
    AssertionError |
    LibraryError |
    # EncodingError | # encodings.nim
    # HttpRequestError |
    # JsonKindError |
    # SslError |
    # TimeoutError |
    UnpackError |
    # JsonParsingError |
    # PunyError |
    DivByZeroError |
    # IOSelectorsException |
    # TimeParseError |
    # TimeFormatParseError |
    ReraiseError |
    OverflowError |
    RangeError |
    ObjectConversionError |
    ResourceExhaustedError

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
