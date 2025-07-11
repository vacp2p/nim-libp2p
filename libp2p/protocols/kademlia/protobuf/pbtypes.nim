# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
import options
import ../../../utility
import ../../../multiaddress

type
  #[
TODO(Ben): ...
- Doc comment this
- Consider the Option pattern here. 
 - I don't think a record can exist without a key
 - A record that exists in a bucket implies that it _must_ have a timeReceived value
 - a `value == none` signals that an entry is empty, which would be the same as 0-len `seq`
- Consider the idiom "`Record` hase key and value, a RecordEntry has a `Record` and `TimeReceived`"
- consider `timeReceived` be a u64 millisecond representation
- Consider using distinct types:
 - Protobuf getting of fields relies on `seq[byte]`
 - mitiprotobuf has similar reqs
 - tried the `type Foo = object\n  data: seq[byte]` pattern and this caused a 
   painful breadtrail of errors
]#
  Record* {.public.} = object
    key*: Option[seq[byte]]
    value*: Option[seq[byte]]
    timeReceived*: Option[string]

  MessageType* = enum
    putValue = 0
    getValue = 1
    addProvider = 2
    getProviders = 3
    findNode = 4
    # TODO(Ben): Raise compiler warning where this deprecated variant is used
    ping = 5 # Deprecated

  ConnectionType* = enum
    notConnected = 0
    connected = 1
    canConnect = 2 # Unused
    cannotConnect = 3 # Unused

  Peer* {.public.} = object
    # TODO: use PeerId
    id*: seq[byte]
    addrs*: seq[MultiAddress]
    connection*: ConnectionType

  Message* {.public.} = object
    msgType*: MessageType
    # TODO: use distinct type
    key*: Option[seq[byte]]
    record*: Option[Record]
    closerPeers*: seq[Peer]
    providerPeers*: seq[Peer]
