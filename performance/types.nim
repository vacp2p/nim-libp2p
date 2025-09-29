type LatencyStats* = object
  minLatencyMs*: float
  maxLatencyMs*: float
  avgLatencyMs*: float

type Stats* = object
  scenarioName*: string
  totalSent*: int
  totalReceived*: int
  latency*: LatencyStats

type LatencyChartData* = object
  prNumber*: int
  scenario*: string
  latency*: LatencyStats

type DockerStatsSample* = object
  timestamp*: float
  cpuPercent*: float
  memUsageMB*: float
  netRxMB*: float
  netTxMB*: float

type CsvData* = object
  samples*: seq[DockerStatsSample]
  downloadRate*: seq[float]
  uploadRate*: seq[float]

type TestRun* = object
  name*: string
  data*: CsvData

type GitHubEnv* = object
  runId*: string
  stepSummary*: string
  commentSummaryPath*: string
  prNumber*: string
  prHeadSha*: string
  githubSha*: string
  marker*: string
  sharedVolumePath*: string
  dockerStatsPrefix*: string
  latencyHistoryPath*: string

type ChartConfig* = object
  colors*: seq[string]
  width*: int
  height*: int

type ResourceChartType* = enum
  Cpu
  Memory
  NetThroughput
  NetTotal

type ResourceChartConfig* = object
  title*: string
  yAxis*: string
  chartType*: ResourceChartType
