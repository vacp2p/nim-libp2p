# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import tables, results
import ../../../../libp2p/protocols/pubsub/[gossipsub/partial_message]
import ../../../tools/[unittest]
import ./my_partial_message

proc toBytes(s: string): seq[byte] =
  return cast[seq[byte]](s)

suite "MyPartialMessage":
  test "partsMetadata":
    var pm = MyPartialMessage(
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
      want: @[4, 5, 6],
    )
    check pm.partsMetadata().data ==
      rawMetadata(@[3, 2, 1], Meta.have) & rawMetadata(@[4, 5, 6], Meta.want)

  test "materializeParts":
    var pm = MyPartialMessage(
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable
    )
    var dataRes: Result[PartsData, string]

    # exists: 1
    dataRes = pm.materializeParts(rawMetadata(@[1], Meta.want))
    check dataRes.isOk()
    check dataRes.get() == pm.data[1]

    # does not exist: 5
    dataRes = pm.materializeParts(rawMetadata(@[5], Meta.want))
    check dataRes.isOk()
    check dataRes.get().len == 0

    # exists: 2 + 3
    dataRes = pm.materializeParts(rawMetadata(@[2, 3], Meta.want))
    check dataRes.isOk()
    check dataRes.get() == pm.data[2] & pm.data[3]

    # exists: 2 + 3;  ignored: 5, 6, 7, 9, 10 
    dataRes = pm.materializeParts(rawMetadata(@[2, 5, 6, 7, 3, 9, 10], Meta.want))
    check dataRes.isOk()
    check dataRes.get() == pm.data[2] & pm.data[3]

    # metadata is not valid
    dataRes = pm.materializeParts(@[1.byte])
    check dataRes.isErr()
