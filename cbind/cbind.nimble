mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C bindings for LibP2P implementation"
license = "MIT"

import os, strutils, sequtils

# The rest of dependencies is inherited from parent libp2p.nimble via nimble.paths
requires "taskpools >= 0.1.0"
# ffi/cbor_serialization aren't in the nimble registry, so nimble can't resolve
# them as `requires`; install_pinned fetches them from .pinned instead.

task install_pinned,
  "Install cbind's pinned deps (taskpools, cbor_serialization, nim-ffi)":
  # cbind-scoped lock; kept out of the root .pinned so the Nim 2.2.4 CI job stays green.
  if not dirExists("nimbledeps"):
    mkDir("nimbledeps")
  let deps = readFile(".pinned").splitWhitespace().mapIt(it.split(";", 1)[1])
  exec "nimble install -y " & deps.join(" ")

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
    " --opt:size --noMain --mm:refc --header -d:metrics" &
    " --nimMainPrefix:libp2p --nimcache:nimcache libp2p.nim"

task libDynamic, "Generate dynamic bindings":
  buildCBindings "dynamic", ""

task libStatic, "Generate static bindings":
  buildCBindings "static", ""

proc findNatPkgDir(): string =
  # Match the top-level Makefile: nimble installs deps under pkgs2 on newer
  # versions and pkgs on older ones; resolve from either.
  for base in ["../nimbledeps/pkgs2", "../nimbledeps/pkgs"]:
    if dirExists(base):
      for d in listDirs(base):
        if d.extractFilename().startsWith("nat_traversal-"):
          return d
  quit "nat_traversal package not found under ../nimbledeps/pkgs2 or " &
    "../nimbledeps/pkgs; run 'nimble install_pinned' first"

task examples, "Build and run C bindings examples":
  buildCBindings "static", ""
  # libp2p.a transitively references miniupnpc and libnatpmp via nat_traversal.
  # Build the vendored .a's via the parent Makefile and link them in.
  exec "make -C .. nat_libs"
  let natPkg = findNatPkgDir()
  # miniupnpc's unix Makefile drops the .a under build/, but its Makefile.mingw
  # drops it at the package root. Match the parent Makefile's per-OS choice.
  let upnpA =
    when defined(windows):
      natPkg / "vendor/miniupnp/miniupnpc/libminiupnpc.a"
    else:
      natPkg / "vendor/miniupnp/miniupnpc/build/libminiupnpc.a"
  let pmpA = natPkg / "vendor/libnatpmp-upstream/libnatpmp.a"
  let natLibs = upnpA & " " & pmpA
  exec "g++ -I. -o ../build/cbindings ./examples/cbindings.c ../build/libp2p.a " &
    natLibs & " -pthread"
  exec "g++ -I. -o ../build/echo ./examples/echo.c ../build/libp2p.a " & natLibs &
    " -pthread"
  exec "../build/cbindings"
  exec "../build/echo"
