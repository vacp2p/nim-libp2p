import chronos

const
  IdLength* = 32 # 256-bit IDs
  k* = 20 # replication parameter
  alpha* = 10 # concurrency parameter
  ttl* = 24.hours
  maxBuckets* = 256

const KadCodec* = "/ipfs/kad/1.0.0"
