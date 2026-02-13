mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C bindings for LibP2P implementation"
license = "MIT"

# The rest of dependencies is inherited from parent libp2p.nimble via nimble.paths
requires "taskpools >= 0.1.0"

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

  exec "nim c --out:" & buildDir & "/libp2p." & ext & " --threads:on --app:" & app &
    " --opt:size --noMain --mm:refc --header --undef:metrics" &
    " --nimMainPrefix:libp2p --nimcache:nimcache libp2p.nim"

task libDynamic, "Generate dynamic bindings":
  buildCBindings "dynamic", ""

task libStatic, "Generate static bindings":
  buildCBindings "static", ""

task examples, "Build and run C bindings examples":
  buildCBindings "static", ""
  exec "g++ -I. -o ../build/cbindings ./examples/cbindings.c ../build/libp2p.a -pthread"
  exec "g++ -I. -o ../build/mix ./examples/mix.c ../build/libp2p.a -pthread"
  exec "../build/cbindings"
  exec "../build/mix"
