mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C bindings for nim-libp2p, generated via nim-ffi"
license = "MIT"

import os, strutils, sequtils

# Most deps come from the parent libp2p.nimble via nimble.paths; nim-ffi pulls in the rest.
requires "taskpools >= 0.1.0"
requires "https://github.com/logos-messaging/nim-ffi#7e3fd96e7417528fecdd0d685fc8fd29a3fd6bfd"

task install_pinned,
  "Install cbind's pinned deps (taskpools, cbor_serialization, nim-ffi)":
  # cbind-scoped lock; kept out of the repo-root .pinned so the main libp2p CI
  # (which doesn't use these) and its Nim 2.2.4 job stay untouched.
  let deps = readFile(".pinned").splitWhitespace().mapIt(it.split(";", 1)[1])
  exec "nimble install -y " & deps.join(" ")

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
  # Name the output `lib<name>` so the file matches the soname nim derives from
  # the module; `--nimMainPrefix:liblibp2p` matches the `liblibp2pNimMain` symbol
  # nim-ffi's `declareLibrary` imports.
  exec "nim c --out:" & buildDir & "/liblibp2p." & getLibExt() &
    " --threads:on --app:lib --opt:size --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p --nimcache:nimcache libp2p.nim"

task buildffi, "Build the FFI shared library":
  buildFfiLib()

proc genBindingsFor(lang, outDir: string) =
  exec "nim c --threads:on --app:lib --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p -d:ffiGenBindings -d:targetLang=" & lang &
    " -d:ffiOutputDir=" & outDir & " -d:ffiSrcPath=libp2p.nim" & " --nimcache:nimcache_" &
    lang & " -o:/dev/null libp2p.nim"

task genbindings_c, "Generate C bindings (cbind/c_bindings)":
  genBindingsFor("c", "c_bindings")

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

task examples, "Build and run the C bindings examples":
  let lib = "../build/liblibp2p." & getLibExt()
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
