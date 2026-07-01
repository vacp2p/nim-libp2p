mode = ScriptMode.Verbose

packageName = "cbind"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "C/C++ bindings for nim-libp2p, generated via nim-ffi"
license = "MIT"

import os

# Most deps come from the parent libp2p.nimble via nimble.paths; nim-ffi pulls in the rest.
requires "taskpools >= 0.1.0"
requires "https://github.com/logos-messaging/nim-ffi#feat/type-mappings"

proc getLibExt(): string =
  when defined(windows):
    "dll"
  elif defined(macosx):
    "dylib"
  else:
    "so"

task buildffi, "Build the FFI shared library":
  let buildDir = "../build"
  if not dirExists buildDir:
    mkDir buildDir
  # `--nimMainPrefix:liblibp2p` matches the `liblibp2pNimMain` symbol nim-ffi's `declareLibrary` imports.
  exec "nim c --out:" & buildDir & "/libp2p." & getLibExt() &
    " --threads:on --app:lib --opt:size --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p --nimcache:nimcache libp2p.nim"

proc genBindingsFor(lang, outDir: string) =
  exec "nim c --threads:on --app:lib --noMain --mm:refc -d:metrics" &
    " --nimMainPrefix:liblibp2p -d:ffiGenBindings -d:targetLang=" & lang &
    " -d:ffiOutputDir=" & outDir & " -d:ffiSrcPath=libp2p.nim" & " --nimcache:nimcache_" &
    lang & " -o:/dev/null libp2p.nim"

task genbindings_cpp, "Generate C++ bindings (cbind/cpp_bindings)":
  genBindingsFor("cpp", "cpp_bindings")

task genbindings_cddl, "Generate CDDL schema (cbind/cddl_bindings)":
  genBindingsFor("cddl", "cddl_bindings")
