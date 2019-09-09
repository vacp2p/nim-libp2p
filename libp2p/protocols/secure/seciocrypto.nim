## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

type
  Exchanges* {.pure.} = enum
    P256 = "P-256",
    P384 = "P-384",
    P521 = "P-521"

  Ciphers* {.pure.} = enum
    AES256 = "AES-256",
    AES128 = "AES-128"

  Hashes* {.pure.} = enum
    SHA256 = "SHA256"
    SHA512 = "SHA512"

  Propose* = tuple
    rand: seq[byte]
    pubkey: seq[byte]
    exchanges: string
    ciphers: string
    hashes: string
  
  Exchange = tuple
    epubkey: seq[byte]
    signature: seq[byte]

proc proposal*() = discard
proc exchange*() = discard
proc selectBest*() = discard
proc verify*() = discard
proc generateKeys*() = discard
proc verifyNonce*() = discard