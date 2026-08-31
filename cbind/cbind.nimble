mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C bindings for nim-libp2p, generated via nim-ffi"
license = "MIT"

import os, strutils

requires "taskpools >= 0.1.0", "ffi >= 0.3.0", "cbor_serialization == 0.3.0"

proc findInstalledPkgDir(prefix: string): string =
  ## Path of an installed dep dir matching `prefix` (e.g. "ffi-"). Lockfile
  ## and local setup use project-local `nimbledeps`; a plain global install
  ## uses the global store. Check both.
  var bases = @[
    "nimbledeps/pkgs2", "nimbledeps/pkgs", "../nimbledeps/pkgs2", "../nimbledeps/pkgs"
  ]
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
      "*'; run `nimble -l setup -y` from cbind first",
  )

proc ffiDepPaths(): string =
  # A global install writes no nimble.paths; point the compiler at the installed
  # copies.
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
    " -d:chronicles_runtime_filtering=on -d:ffiThreadExitTimeoutMs=5000" & ffiDepPaths() &
    " --nimMainPrefix:liblibp2p --nimcache:nimcache libp2p.nim"

task buildffi, "Build the FFI shared library":
  buildFfiLib()

proc genBindingsFor(lang, outDir: string) =
  # `--compileOnly`: the binding files are written during macro expansion, so
  # codegen is enough — there is nothing to link.
  exec "nim c --threads:on --noMain --mm:refc -d:metrics --compileOnly" &
    " -d:chronicles_runtime_filtering=on --nimMainPrefix:liblibp2p" &
    " -d:ffiGenBindings -d:targetLang=" & lang & " -d:ffiOutputDir=" & outDir &
    " -d:ffiSrcPath=libp2p.nim" & ffiDepPaths() & " --nimcache:nimcache_" & lang &
    " libp2p.nim"

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

  for example in [
    "echo", "gossipsub", "kad", "service_disco", "relay", "peerstore", "metrics"
  ]:
    let outBin = "../build/" & example
    exec "gcc -std=c11 -O2 -I c_bindings -I " & vendor & " examples/" & example & ".c " &
      cborObjsStr & " " & lib & " -pthread -Wl,-rpath,'$ORIGIN' -o " & outBin
    exec outBin
