## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import nimcrypto/utils

const
  ShortDumpMax = 24

func shortLog*(item: openarray[byte]): string =
  if item.len <= ShortDumpMax:
    item.toHex()
  else:
    const split = ShortDumpMax div 2
    let
      aslice = item[0..<split].toHex()
      bslice = item[^split..item.high].toHex()
    aslice & "..." & bslice

func shortLog*(item: string): string =
  if item.len <= ShortDumpMax:
    item
  else:
    const split = ShortDumpMax div 2
    let
      aslice = item[0..<split]
      bslice = item[^split..item.high]
    aslice & "..." & bslice
