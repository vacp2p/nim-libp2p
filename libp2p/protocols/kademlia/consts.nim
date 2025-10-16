import chronos

const
  IdLength* = 32 # 256-bit IDs

  DefaultMaxBuckets* = 256
  DefaultTimeout* = 5.seconds
  DefaultRetries* = 5
  DefaultReplication* = 20 ## aka `k` in the spec
  DefaultAlpha* = 10 # concurrency parameter
  DefaultTTL* = 24.hours
  DefaultQuorum* = 5 # number of GetValue responses needed to decide

const KadCodec* = "/ipfs/kad/1.0.0"
