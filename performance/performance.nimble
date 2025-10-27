# Package

version = "0.1.0"
author = "Status Research & Development GmbH"
description = "Small-scale distributed performance & reliability tests for nim-libp2p."
license = "MIT"

# Dependencies

requires "nim >= 2.2.4", "chronicles", "chronos", "unittest2"

task performance, "Run performance tests":
  exec "nim c -r --mm:refc -d:release -o:/tmp/scenarios_performance -d:chronicles_log_level:DEBUG ./scenarios_performance.nim"

task reliability, "Run reliability tests":
  exec "nim c -r --mm:refc -d:release -o:/tmp/scenarios_reliability -d:chronicles_log_level:DEBUG ./scenarios_reliability.nim"
