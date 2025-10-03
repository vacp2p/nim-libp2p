# Package

version = "0.1.0"
author = "Status Research & Development GmbH"
description = "A new awesome nimble package"
license = "MIT"
srcDir = "src"
bin = @["performance"]

# Dependencies

requires "nim >= 2.2.4", "chronicles", "chronos", "unittest2"

task performance, "Run performance tests":
  exec "nim c -r -d:release -o:/tmp/scenarios_performance -d:chronicles_log_level:INFO ./scenarios_performance.nim"
