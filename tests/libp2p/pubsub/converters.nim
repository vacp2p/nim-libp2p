# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results
import ../../../libp2p/[peerid, protocols/pubsub/rpc/message]

converter toOptString*(a: string): Opt[string] =
  Opt.some(a)

converter toOptBool*(a: bool): Opt[bool] =
  Opt.some(a)

converter toOptUint32*(a: uint32): Opt[uint32] =
  Opt.some(a)

converter toOptUint64*(a: uint64): Opt[uint64] =
  Opt.some(a)

converter toOptSeqByte*(a: seq[byte]): Opt[seq[byte]] =
  Opt.some(a)

converter toOptMessageId*(a: MessageId): Opt[MessageId] =
  Opt.some(a)

converter toOptPeerId*(a: PeerId): Opt[PeerId] =
  Opt.some(a)
