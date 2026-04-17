mode = ScriptMode.Verbose

packageName = "simulation"
version = "0.1.0"
author = "Status Research & Development GmbH"
description = "nim-libp2p network simulation"
license = "MIT"

# Only simulation-specific deps here.
# Parent libp2p deps (chronos, stew, etc.) are resolved via config.nims --path
requires "redis"
