# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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

type DockerStatsSample* = object of RootObj
  timestamp*: float
  cpuPercent*: float
  memUsageMB*: float
  netRxMB*: float
  netTxMB*: float

type ResourceChartsSample* = object of DockerStatsSample
  downloadRate*: float
  uploadRate*: float

type TestRun* = object
  name*: string
  data*: seq[ResourceChartsSample]

type ResourceChartType* = enum
  Cpu
  Memory
  NetThroughput
  NetTotal

type ResourceChartData* = object
  title*: string
  yAxis*: string
  chartType*: ResourceChartType

const defaultColors* = @["🔵", "🟢", "🔴", "🟠"]

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
