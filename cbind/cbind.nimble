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

# nim-ffi library, built in parallel to the legacy cbind above (see libp2p_ffi.nim).
# Renamed over libp2p.nim at the flip PR, which drops everything above this line.

proc findInstalledPkgDir(prefix: string): string =
  ## Path of an installed dep dir matching `prefix` (e.g. "ffi-"). install_pinned
  ## drops cbind's pinned deps under the project-local `nimbledeps/pkgs2`; a plain
  ## `nimble install` uses the global store. Check both.
  var bases = @["nimbledeps/pkgs2", "../nimbledeps/pkgs2"]
  let home = getEnv("HOME")
  if home.len > 0:
    bases.add home & "/.nimble/pkgs2"
  for base in bases:
    if not dirExists(base):
      continue
    for entry in listDirs(base):
      if entry.extractFilename().startsWith(prefix):
        return entry
  raise newException(
    IOError,
    "could not locate installed package '" & prefix &
      "*'; run `nimble install_pinned` first",
  )

proc ffiDepPaths(): string =
  # ffi and cbor_serialization aren't cbind `requires` (they're not in the nimble
  # registry, so setup can't resolve them onto nimble.paths); point the compiler
  # at the installed copies. Their transitive deps (chronos, serialization, stew,
  # results, faststreams, …) are libp2p deps already on the inherited root paths.
  " --path:" & findInstalledPkgDir("ffi-") & " --path:" &
    findInstalledPkgDir("cbor_serialization-")

proc ffiLibExt(): string =
  when defined(windows):
    "dll"
  elif defined(macosx):
    "dylib"
  else:
    "so"

proc buildFfiLib() =
  let buildDir = "../build"
  if not dirExists(buildDir):
    mkDir(buildDir)
  # libplum's vendored C is pulled in via Nim `{.compile.}`, so no separate
  # native-library build step is needed here.
  # Name the output `lib<name>` so the file matches the soname nim derives from
  # the module; `--nimMainPrefix:liblibp2p` matches the `liblibp2pNimMain` symbol
  # nim-ffi's `declareLibrary` imports.
  # ffiThreadExitTimeoutMs: bound the FFI thread's graceful-shutdown wait; the
  # 1500ms default is too tight for libp2pDestroy's switch.stop() over many conns.
  exec "nim c --out:" & buildDir & "/liblibp2p." & ffiLibExt() &
    " --threads:on --app:lib --opt:size --noMain --mm:refc -d:metrics" &
    " -d:ffiThreadExitTimeoutMs=5000" & ffiDepPaths() &
    " --nimMainPrefix:liblibp2p --nimcache:nimcache libp2p_ffi.nim"

task buildffi, "Build the FFI shared library":
  buildFfiLib()

proc genBindingsFor(lang, outDir: string) =
  exec "nim c --threads:on --app:lib --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p -d:ffiGenBindings -d:targetLang=" & lang &
    " -d:ffiOutputDir=" & outDir & " -d:ffiSrcPath=libp2p_ffi.nim" & ffiDepPaths() &
    " --nimcache:nimcache_" & lang & " -o:/dev/null libp2p_ffi.nim"

task genbindings_c, "Generate C bindings (cbind/c_bindings)":
  genBindingsFor("c", "c_bindings")

task genbindings_cddl, "Generate CDDL schema (cbind/cddl_bindings)":
  genBindingsFor("cddl", "cddl_bindings")

proc findFfiVendorDir(): string =
  ## TinyCBOR sources vendored inside the installed nim-ffi package.
  let vendor = findInstalledPkgDir("ffi-") & "/ffi/codegen/templates/cpp/vendor"
  if not fileExists(vendor & "/tinycbor/cbor.h"):
    raise newException(IOError, "vendored tinycbor missing under " & vendor)
  vendor

task examples, "Build and run the C bindings examples":
  let lib = "../build/liblibp2p." & ffiLibExt()
  if not fileExists(lib):
    buildFfiLib()
  if not fileExists("c_bindings/libp2p.h"):
    genBindingsFor("c", "c_bindings")

  let vendor = findFfiVendorDir()
  var cborObjs: seq[string]
  for name in [
    "cborencoder", "cborencoder_close_container_checked", "cborparser",
    "cborparser_dup_string", "cborerrorstrings",
  ]:
    let obj = "../build/" & name & ".o"
    exec "gcc -std=c99 -O2 -fPIC -I " & vendor & " -I " & vendor & "/tinycbor -c " &
      vendor & "/tinycbor/" & name & ".c -o " & obj
    cborObjs.add obj
  let cborObjsStr = cborObjs.join(" ")

  for example in ["echo", "gossipsub"]:
    let outBin = "../build/" & example
    exec "gcc -std=c11 -O2 -I c_bindings -I " & vendor & " examples/" & example & ".c " &
      cborObjsStr & " " & lib & " -pthread -Wl,-rpath,'$ORIGIN' -o " & outBin
    exec outBin
