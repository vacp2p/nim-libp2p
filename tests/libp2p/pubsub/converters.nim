# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results
import ../../../libp2p/[protocols/pubsub/rpc/message]

converter toOptString*(a: string): Opt[string] =
  Opt.some(a)

converter toOptBool*(a: bool): Opt[bool] =
  Opt.some(a)

converter toOptSeqByte*(a: seq[byte]): Opt[seq[byte]] =
  Opt.some(a)
