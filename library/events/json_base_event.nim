# JSON Event definition
#
# This file defines de JsonEvent type, which serves as the base
# for all event types in the library
#
# Reference specification:
# https://github.com/vacp2p/rfc/blob/master/content/docs/rfcs/36/README.md#jsonsignal-type

type JsonEvent* = ref object of RootObj
  eventType* {.requiresInit.}: string

method `$`*(jsonEvent: JsonEvent): string {.base.} =
  discard
  # All events should implement this
