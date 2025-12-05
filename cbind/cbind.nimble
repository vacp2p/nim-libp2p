mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C bindings for LibP2P implementation"
license = "MIT"

# Dependencies are inherited from parent libp2p.nimble via nimble.paths
# We don't need `requires` here since we run tasks, not build a package

include "../common.nims"

proc getLibExt(libType: string): string =
  if libType == "static":
    "a"
  else:
    when defined(windows):
      "dll"
    elif defined(macosx):
      "dylib"
    else:
      "so"

proc buildCBindings(libType: string, params = "") =
  let buildDir = "../build"

  if not dirExists buildDir:
    mkDir buildDir

  var extra_params = params
  for i in 2 ..< paramCount():
    extra_params &= " " & paramStr(i)

  let ext = getLibExt(libType)
  let app = if libType == "static": "staticlib" else: "lib"

  exec nimc & " " & lang & " --out:" & buildDir & "/libp2p." & ext &
    " --threads:on --app:" & app &
    " --opt:size --noMain --mm:refc --header --undef:metrics" &
    " --nimMainPrefix:libp2p --nimcache:nimcache" & " -d:asyncTimer=system " & cfg & " " &
    flags & " libp2p.nim"

task libDynamic, "Generate dynamic bindings":
  buildCBindings "dynamic", ""

task libStatic, "Generate static bindings":
  buildCBindings "static", ""

task examples, "Build and run C bindings examples":
  buildCBindings "static", ""
  exec "g++ -I. -o ../build/cbindings ./examples/cbindings.c ../build/libp2p.a -pthread"
  exec "../build/cbindings"
