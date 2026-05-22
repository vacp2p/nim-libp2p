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
  # libp2p.a contains nat_traversal Nim wrappers that reference miniupnpc /
  # libnatpmp C symbols. Build the vendored .a's via the parent Makefile and
  # link them in (shell globs resolve the version-suffixed package dir).
  exec "make -C .. nat_libs"
  let natLibs =
    "../nimbledeps/pkgs2/nat_traversal-*/vendor/miniupnp/miniupnpc/build/libminiupnpc.a " &
    "../nimbledeps/pkgs2/nat_traversal-*/vendor/libnatpmp-upstream/libnatpmp.a"
  exec "g++ -I. -o ../build/cbindings ./examples/cbindings.c ../build/libp2p.a " & natLibs & " -pthread"
  exec "g++ -I. -o ../build/echo ./examples/echo.c ../build/libp2p.a " & natLibs & " -pthread"
  exec "../build/cbindings"
  exec "../build/echo"
