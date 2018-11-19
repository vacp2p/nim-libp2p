mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "Nim"]

requires "nim > 0.18.0"

task tests, "Runs the test suite":
  exec "nim c -r tests/testpbvarint"