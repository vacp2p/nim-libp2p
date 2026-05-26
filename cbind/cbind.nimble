mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C bindings for LibP2P implementation"
license = "MIT"

# The rest of dependencies is inherited from parent libp2p.nimble via nimble.paths
requires "taskpools >= 0.1.0"

import std/[os, strutils]

proc natTraversalPkgDir(): string =
  ## Resolve the version-suffixed ``nat_traversal-...`` directory under
  ## ``nimbledeps/pkgs2``. Avoids shell globs that don't expand under cmd.exe.
  for d in listDirs("../nimbledeps/pkgs2"):
    if d.extractFilename.startsWith("nat_traversal-"):
      return d
  raise newException(
    OSError, "nat_traversal package not found; run 'nimble install_pinned' first"
  )

proc natLibLinkFlags(): string =
  let pkg = natTraversalPkgDir()
  # miniupnpc's unix Makefile drops the .a under build/; the Windows
  # Makefile.mingw drops it at the package root. Match each.
  let upnp =
    when defined(windows):
      pkg / "vendor" / "miniupnp" / "miniupnpc" / "libminiupnpc.a"
    else:
      pkg / "vendor" / "miniupnp" / "miniupnpc" / "build" / "libminiupnpc.a"
  let natpmp = pkg / "vendor" / "libnatpmp-upstream" / "libnatpmp.a"
  upnp & " " & natpmp

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

  # A shared library (--app:lib) is fully linked, so it must resolve the
  # miniupnpc / libnatpmp C symbols pulled in via nat_traversal. Build the
  # vendored .a's and hand them to the linker. A static lib (--app:staticlib)
  # is only archived; its consumer links those in later (see the examples task).
  var linkFlags = ""
  if libType == "dynamic":
    exec "make -C .. nat_libs"
    linkFlags = " --passL:\"" & natLibLinkFlags() & "\""

  exec "nim c --out:" & buildDir & "/libp2p." & ext & " --threads:on --app:" & app &
    " --opt:size --noMain --mm:refc --header --undef:metrics" &
    " --nimMainPrefix:libp2p --nimcache:nimcache" & linkFlags & " libp2p.nim"

task libDynamic, "Generate dynamic bindings":
  buildCBindings "dynamic", ""

task libStatic, "Generate static bindings":
  buildCBindings "static", ""

task examples, "Build and run C bindings examples":
  buildCBindings "static", ""
  # libp2p.a contains nat_traversal Nim wrappers that reference miniupnpc /
  # libnatpmp C symbols. Build the vendored .a's via the parent Makefile and
  # link them in.
  exec "make -C .. nat_libs"
  let natLibs = natLibLinkFlags()
  exec "g++ -I. -o ../build/cbindings ./examples/cbindings.c ../build/libp2p.a " &
    natLibs & " -pthread"
  exec "g++ -I. -o ../build/echo ./examples/echo.c ../build/libp2p.a " & natLibs &
    " -pthread"
  exec "../build/cbindings"
  exec "../build/echo"
