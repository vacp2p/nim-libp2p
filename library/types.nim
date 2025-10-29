import ../libp2p

# TODO: remove and implement custom event callbacks if needed
# Example:
#   proc onSomeEvent(ctx: ptr LibP2PContext): Libp2pCallback =
#    return proc(msg: string) {.gcsafe.} =
#      callEventCallback(ctx, "onSomeEvent"):
#        $JsonMyEvent.new(msg)
type AppCallbacks* = ref object

type LibP2P* = ref object
  switch: Switch
