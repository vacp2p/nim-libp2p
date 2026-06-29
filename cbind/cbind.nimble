mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C/C++ bindings for nim-libp2p, generated via nim-ffi"
license = "MIT"

import os, strutils

# Most deps come from the parent libp2p.nimble via nimble.paths; nim-ffi pulls in the rest.
requires "taskpools >= 0.1.0"
requires "https://github.com/logos-messaging/nim-ffi#4bac7a7bc6716a4db681fb2ed20a601ae19de032"

proc getLibExt(): string =
  when defined(windows):
    "dll"
  elif defined(macosx):
    "dylib"
  else:
    "so"

proc buildFfiLib() =
  let buildDir = "../build"
  if not dirExists buildDir:
    mkDir buildDir
  # `--nimMainPrefix:liblibp2p` matches the `liblibp2pNimMain` symbol nim-ffi's `declareLibrary` imports.
  exec "nim c --out:" & buildDir & "/libp2p." & getLibExt() &
    " --threads:on --app:lib --opt:size --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p --nimcache:nimcache libp2p.nim"

task buildffi, "Build the FFI shared library":
  buildFfiLib()

proc genBindingsFor(lang, outDir: string) =
  exec "nim c --threads:on --app:lib --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p -d:ffiGenBindings -d:targetLang=" & lang &
    " -d:ffiOutputDir=" & outDir & " -d:ffiSrcPath=libp2p.nim" & " --nimcache:nimcache_" &
    lang & " -o:/dev/null libp2p.nim"

task genbindings_cpp, "Generate C++ bindings (cbind/cpp_bindings)":
  genBindingsFor("cpp", "cpp_bindings")

task genbindings_cddl, "Generate CDDL schema (cbind/cddl_bindings)":
  genBindingsFor("cddl", "cddl_bindings")

proc findFfiVendorDir(): string =
  ## Locates the TinyCBOR sources vendored inside the installed nim-ffi package.
  var bases = @["../nimbledeps/pkgs2"]
  let home = getEnv("HOME")
  if home.len > 0:
    bases.add home & "/.nimble/pkgs2"
  for base in bases:
    if not dirExists(base):
      continue
    for entry in listDirs(base):
      if not entry.extractFilename.startsWith("ffi-"):
        continue
      let vendor = entry & "/ffi/codegen/templates/cpp/vendor"
      if fileExists(vendor & "/tinycbor/cbor.h"):
        return vendor
  raise newException(
    IOError, "could not locate nim-ffi's vendored tinycbor; run `nimble setup` first"
  )

task examples, "Build and run the C++ bindings examples":
  let lib = "../build/libp2p." & getLibExt()
  if not fileExists(lib):
    buildFfiLib()
  if not fileExists("cpp_bindings/libp2p.hpp"):
    genBindingsFor("cpp", "cpp_bindings")

  let vendor = findFfiVendorDir()
  # TinyCBOR is C99; compile it with the C compiler (g++ would treat .c as C++).
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
    exec "g++ -std=c++20 -O2 -I cpp_bindings -I " & vendor & " examples/" & example &
      ".cpp " & cborObjsStr & " " & lib & " -pthread -Wl,-rpath,'$ORIGIN' -o " & outBin
    exec outBin
