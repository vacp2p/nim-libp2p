# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import ../../utility, ../../errors

type ValidationResult* {.pure, public.} = enum
  Accept
  Reject
  Ignore

type
  PublishingError* = object of LPError

  NoTopicSpecifiedError* = object of PublishingError
  PayloadIsEmptyError* = object of PublishingError
  DuplicateMessageError* = object of PublishingError
  NotSubscribedToTopicError* = object of PublishingError
  NoPeersToPublishError* = object of PublishingError
  GeneratingMessageIdError* = object of PublishingError
