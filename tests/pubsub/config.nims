import strutils

proc hasSkipParentCfg(): bool =
  for param in 0 ..< paramCount():
    if "skipParent" in paramStr(param):
      return true

when hasSkipParentCfg():
  import ../config.nims
