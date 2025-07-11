import chronos

const
  IdLength* = 32 # 256-bit IDs
  k* = 20 # replication parameter
  KAD_ALPHA* = 10 # concurrency parameter
  maxBuckets* = 256

const KadCodec* = "/ipfs/kad/1.0.0"
