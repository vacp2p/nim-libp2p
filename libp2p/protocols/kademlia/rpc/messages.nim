import options

# XXX: Not clear what we want this to look like
# https://github.com/libp2p/specs/tree/master/pubsub/gossipsub#protobuf
# https://github.com/libp2p/specs/blob/master/pubsub/README.md

# http://xlattice.sourceforge.net/components/protocol/kademlia/specs.html
# > All RPC packets are required to carry an RPC identifier assigned by the sender and echoed in the reply. This is a quasi-random number of length B (160 bits).

# ping() -> pong()
# findnode(id) -> return k tcontacts

# https://github.com/libp2p/specs/pull/108/files err

# store
# findvalue

# XXX: Right now this is modelled after pubsub, should fix
# Let's try more minimal

# XXX: Use sum type for RPCMsg?
# https://github.com/nim-lang/Nim/wiki/Common-Criticisms#sum-types-are-weird

type
  #Message* = object
  #  fromPeer*: seq[byte]
  #  data*: seq[byte]
    #seqno?, sig? key?
  
  #ControlMessage* = object
  #  ping*: bool
  #  findnode*: seq[byte]

  RPCMsg* = object
    #messages*: seq[Message]
    #control*: Option[ControlMessage]
    ping*: Option[bool]
    findnode*: Option[seq[byte]]
