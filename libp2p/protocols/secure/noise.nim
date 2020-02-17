## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import secure,
       ../../crypto/chacha20poly1305,
       ../../crypto/curve25519

template unimplemented: untyped =
  doAssert(false, "Not implemented")
       
type
  Noise = ref object of Secure
    privateKey: Curve25519Key
    publicKey: Curve25519Key
    
  NoiseConnection = ref object of Connection

method init*(p: Noise) {.base, gcsafe.} =
  unimplemented()
  
method secure*(p: Noise, conn: Connection): Future[Connection] {.async, gcsafe.} =
  unimplemented()

proc initNoise(p: Noise, privateKey: Curve25519Key) =
  p.privateKey = privateKey
  p.publicKey = privateKey.public()
  
proc newNoise*(privateKey: Curve25519Key): Noise =
  new result
  initNoise(result, privateKey)

proc newNoise*(): Noise =
  new result
  # generate a random new keypair
  
