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
requires "libp2p#5f6b8e86a5c294cab9ed23afcaf496c18057d079"