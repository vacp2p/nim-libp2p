# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import ../../utility, ../../errors

type ValidationResult* {.pure, public.} = enum
  Accept
  Reject
  Ignore

type PublishOutcome* {.pure, public.} = enum
  NoTopicSpecified
  DuplicateMessage
  NoPeersToPublish
  CannotGenerateMessageId
