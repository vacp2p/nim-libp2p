import algorithm, sequtils, strformat, strutils, tables
import ../types
import ./common

const CHART_CONFIGS = [
  ResourceChartConfig(
    title: "CPU % vs Time", yAxis: "CPU %", chartType: ResourceChartType.Cpu
  ),
  ResourceChartConfig(
    title: "Memory Usage (MB)",
    yAxis: "Memory (MB)",
    chartType: ResourceChartType.Memory,
  ),
  ResourceChartConfig(
    title: "Network Throughput (MB/s)",
    yAxis: "MB/s",
    chartType: ResourceChartType.NetThroughput,
  ),
  ResourceChartConfig(
    title: "Total Network Data (MB)", yAxis: "MB", chartType: ResourceChartType.NetTotal
  ),
]

proc readCsv(path: string): CsvData =
  let lines = readFile(path).splitLines()
  var data = CsvData()
  for i, line in lines:
    if i == 0 or line.len == 0:
      continue
    let cols = line.split(',')
    if cols.len < 7:
      continue
    try:
      data.samples.add(
        DockerStatsSample(
          timestamp: parseFloat(cols[0]),
          cpuPercent: parseFloat(cols[1]),
          memUsageMB: parseFloat(cols[2]),
          netRxMB: parseFloat(cols[5]),
          netTxMB: parseFloat(cols[6]),
        )
      )
      data.downloadRate.add(parseFloat(cols[3]))
      data.uploadRate.add(parseFloat(cols[4]))
    except ValueError:
      discard
  return data

proc buildSeries(
    runs: seq[TestRun], config: ResourceChartConfig
): seq[(string, seq[float])] =
  var series: seq[(string, seq[float])]
  for run in runs:
    case config.chartType
    of ResourceChartType.Cpu:
      if run.data.samples.len > 0:
        series.add (run.name, run.data.samples.mapIt(it.cpuPercent))
    of ResourceChartType.Memory:
      if run.data.samples.len > 0:
        series.add (run.name, run.data.samples.mapIt(it.memUsageMB))
    of ResourceChartType.NetThroughput:
      if run.data.downloadRate.len > 0:
        series.add (run.name & " download", run.data.downloadRate)
      if run.data.uploadRate.len > 0:
        series.add (run.name & " upload", run.data.uploadRate)
    of ResourceChartType.NetTotal:
      if run.data.samples.len > 0:
        series.add (run.name & " download", run.data.samples.mapIt(it.netRxMB))
        series.add (run.name & " upload", run.data.samples.mapIt(it.netTxMB))
  return series

when isMainModule:
  let outDir = "performance/output"
  let csvFiles = findCsvFiles(outDir, "docker_stats").sorted

  if csvFiles.len == 0:
    raiseAssert "No docker_stats*.csv files found in " & outDir

  var groups: Table[string, seq[TestRun]]
  for file in csvFiles:
    let data = readCsv(file)
    if data.samples.len > 0:
      let group = extractTestName(file)
      let run = extractTestName(file, keepSuffix = true)
      groups.mgetOrPut(group, @[]).add TestRun(name: run, data: data)

  var outputSections: seq[string]
  for groupName in groups.keys.toSeq.sorted:
    let runs = groups[groupName]
    outputSections.add fmt"### {groupName}"

    for config in CHART_CONFIGS:
      let chartConfig = getDefaultChartConfig()
      let chart = formatMermaidChart(
        config.title & " - " & groupName,
        "Time (s)",
        config.yAxis,
        runs.buildSeries(config),
        chartConfig,
      )
      if chart.len > 0:
        outputSections.add chart

  let output = outputSections.join("\n")
  let env = getGitHubEnv()

  echo output
  writeGitHubOutputs(output, env, toJobSummary = true, toComment = false)
