# Package

version       = "0.1.0"
author        = "fryorcraken"
description   = "Test libp2p with nimble"
license       = "MIT"
srcDir        = "src"
bin           = @["example"]


# Dependencies

requires "libp2p"
requires "stew"
requires "chronos"