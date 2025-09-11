type LatencyStats* = object
  minLatencyMs*: float
  maxLatencyMs*: float
  avgLatencyMs*: float

type Stats* = object
  scenarioName*: string
  totalSent*: int
  totalReceived*: int
  latency*: LatencyStats
