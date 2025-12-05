# Common NimScript configuration shared across nimble files
# Include this file using: include "nimble/common.nims" (from root)
#                      or: include "../nimble/common.nims" (from subdirectory)

let nimc* = getEnv("NIMC", "nim") # Which nim compiler to use
let lang* = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags* = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose* = getEnv("V", "") notin ["", "0"]

let cfg* =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipUserCfg -f --threads:on --opt:speed"
