mode = ScriptMode.Verbose

packageName = "tests"
version = "1.0.0"
author = "Status Research & Development GmbH"
description = "Tests for LibP2P implementation"
license = "MIT"

requires "libbacktrace >= 0.2.0", "unittest2 >= 0.2.5",
  "chronicles >= 0.12.3",
  "chronos#ebc2d239ba49d175726db5d06b1555ae25b213a1",
  "https://github.com/vladopajic/nim-unittest3#dea5bdb8cef80846726b80348e86249c385b8786"
