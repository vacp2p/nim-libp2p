{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos
import
  ../libp2p/[
    transports/tcptransport,
    upgrademngrs/upgrade,
    builders,
    protocols/connectivity/autonatv2/types,
      # nameresolving/nameresolver,
      # nameresolving/mockresolver,
  ],
  ./helpers

proc checkEncodeDecode[T](msg: T) =
  # this would be equivalent of doing the following (e.g. for DialBack)
  # check msg == DialBack.decode(msg.encode()).get()
  check msg == T.decode(msg.encode()).get()

suite "AutonatV2":
  teardown:
    checkTrackers()

  asyncTest "encode/decode messages":
    # DialRequest
    let dialReq = DialRequest(
      addrs:
        @[
          MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
          MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
        ],
      nonce: 42,
    )
    checkEncodeDecode(dialReq)

    # DialResponse
    let dialResp =
      DialResponse(status: ResponseStatus.Ok, addrIdx: 1, dialStatus: DialStatus.Ok)
    checkEncodeDecode(dialResp)

    # DialDataRequest
    let dataReq = DialDataRequest(addrIdx: 0, numBytes: 128)
    checkEncodeDecode(dataReq)

    # DialDataResponse
    let dataResp = DialDataResponse(data: @[1'u8, 2, 3, 4, 5])
    checkEncodeDecode(dataResp)

    # AutonatV2Msg - DialRequest
    let msgReq = AutonatV2Msg(msgType: MsgType.DialRequest, dialReq: dialReq)
    checkEncodeDecode(msgReq)

    # AutonatV2Msg - DialResponse
    let msgResp = AutonatV2Msg(msgType: MsgType.DialResponse, dialResp: dialResp)
    checkEncodeDecode(msgResp)

    # AutonatV2Msg - DialDataRequest
    let msgDataReq =
      AutonatV2Msg(msgType: MsgType.DialDataRequest, dialDataReq: dataReq)
    checkEncodeDecode(msgDataReq)

    # AutonatV2Msg - DialDataResponse
    let msgDataResp =
      AutonatV2Msg(msgType: MsgType.DialDataResponse, dialDataResp: dataResp)
    checkEncodeDecode(msgDataResp)

    # DialBack
    let dialBack = DialBack(nonce: 123456)
    checkEncodeDecode(dialBack)

    # DialBackResponse
    let dialBackResp = DialBackResponse(status: DialBackStatus.Ok)
    checkEncodeDecode(dialBackResp)
