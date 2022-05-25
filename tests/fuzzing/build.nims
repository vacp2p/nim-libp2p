#!/usr/bin/env nim

import strutils, os

withDir "../../":
  exec "nimble install -dy"

for file in listFiles("."):
  if file.endsWith(".nim"):
    let execName = file[0 ..< ^4]
    exec """nim c -d:libFuzzer -d:llvmFuzzer -d:chronicles_log_level=warn --noMain --cc=clang --passC="-fsanitize=fuzzer" --passL="-fsanitize=fuzzer" -o=""" & (getEnv("BIN") / execName) & " " & file
