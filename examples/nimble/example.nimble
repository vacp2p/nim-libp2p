# Package

version       = "0.1.0"
author        = "fryorcraken"
description   = "Test libp2p with nimble"
license       = "MIT"
srcDir        = "src"
bin           = @["example"]


# Dependencies

requires "stew"
requires "chronos"
requires "libp2p"