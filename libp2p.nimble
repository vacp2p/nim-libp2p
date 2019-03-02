mode = ScriptMode.Verbose

packageName   = "libp2p"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "LibP2P implementation"
license       = "MIT"
skipDirs      = @["tests", "examples", "Nim"]

requires "nim > 0.18.0",
         "nimcrypto >= 0.3.9",
         "chronos"

task test, "Runs the test suite":
  exec "nim c -r tests/testvarint"
  exec "nim c -r tests/testbase58"
  exec "nim c -r tests/testbase32"
  exec "nim c -r tests/testmultiaddress"
  exec "nim c -r tests/testmultihash"
  exec "nim c -r tests/testmultibase"
  exec "nim c -r tests/testcid"
  exec "nim c -r tests/testecnist"
  exec "nim c -r tests/testrsa"
  exec "nim c -r tests/tested25519"
  exec "nim c -r tests/testcrypto"
  exec "nim c -r tests/testdaemon"
