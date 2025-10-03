import json
import os
import parsecsv
import sequtils
import strutils
import ../types

proc findFilesByPattern*(dir: string, pattern: string): seq[string] =
  if not dirExists(dir):
    raiseAssert "Directory not found: " & dir

  var files: seq[string] = @[]
  for entry in walkDir(dir):
    if entry.kind == pcFile and pattern in entry.path:
      files.add(entry.path)
  return files

proc findJsonFiles*(dir: string): seq[string] =
  findFilesByPattern(dir, ".json")

proc findCsvFiles*(dir: string, prefix: string = ""): seq[string] =
  let allCsvFiles = findFilesByPattern(dir, ".csv")
  let files =
    if prefix == "":
      allCsvFiles
    else:
      allCsvFiles.filterIt(prefix in it)

  return files

proc findLogFiles*(dir: string, prefix: string): seq[string] =
  let allLogFiles = findFilesByPattern(dir, ".log")
  return allLogFiles.filterIt(prefix in it)

proc parseJsonFiles*(outputDir: string): seq[JsonNode] =
  var jsons: seq[JsonNode]
  let paths = findJsonFiles(outputDir)

  for path in paths:
    let content = readFile(path)
    let json = parseJson(content)
    jsons.add(json)

  return jsons

proc getGitHubEnv*(): GitHubEnv =
  GitHubEnv(
    runId: getEnv("GITHUB_RUN_ID", ""),
    stepSummary: getEnv("GITHUB_STEP_SUMMARY", "/tmp/summary.txt"),
    commentSummaryPath: getEnv("COMMENT_SUMMARY_PATH", "/tmp/summary.txt"),
    prNumber: getEnv("PR_NUMBER", "unknown"),
    prHeadSha: getEnv("PR_HEAD_SHA", getEnv("GITHUB_SHA", "unknown")),
    githubSha: getEnv("GITHUB_SHA", "unknown"),
    marker: getEnv("MARKER", "<!-- marker -->"),
    sharedVolumePath: getEnv("SHARED_VOLUME_PATH", "performance/output"),
    dockerStatsPrefix: getEnv("DOCKER_STATS_PREFIX", "docker_stats_"),
    latencyHistoryPath: getEnv("LATENCY_HISTORY_PATH", "latency_history"),
  )

proc appendFile(content: string, path: string) =
  let file = open(path, fmAppend)
  file.write(content & "\n")
  file.close()

proc writeGitHubSummary*(content: string, env: GitHubEnv) =
  appendFile(content, env.stepSummary)

proc writeGitHubComment*(content: string, env: GitHubEnv) =
  appendFile(content, env.commentSummaryPath)

proc extractPrNumber*(filename: string): int =
  let base = filename.extractFilename
  if not base.startsWith("pr") or not base.endsWith("_latency.csv"):
    return 0

  let prString = base[2 .. ^13]
  try:
    return parseInt(prString)
  except ValueError:
    return 0

proc extractScenarioType*(scenarioName: string): string =
  if "QUIC" in scenarioName:
    return "QUIC"
  elif scenarioName == "Base test" or "TCP" in scenarioName:
    return "TCP"
  return ""

proc sanitizeFilename*(
    path: string, removePrefix: string = "", removeSuffix: string = ""
): string =
  var name = path.extractFilename

  if removeSuffix != "" and name.endsWith(removeSuffix):
    name = name[0 .. ^(removeSuffix.len + 1)]

  if removePrefix != "" and name.startsWith(removePrefix):
    name = name[removePrefix.len .. ^1]

  return name

proc extractTestName*(path: string, keepSuffix = false): string =
  var name = sanitizeFilename(path, "docker_stats_", ".csv")

  if keepSuffix:
    return name

  let underscorePos = name.rfind('_')
  if underscorePos > 0:
    let suffix = name[underscorePos + 1 .. ^1]
    let isRunNumber = suffix.len > 0 and suffix.allCharsInSet({'0' .. '9'})
    if isRunNumber:
      name = name[0 .. underscorePos - 1]

  return name

proc generateLegend*(items: seq[string], colors: seq[string]): string =
  var legendItems: seq[string]
  for i, item in items:
    let color =
      if i < colors.len:
        colors[i]
      else:
        "⚫"
    legendItems.add(color & " " & item)
  return "<sub>" & legendItems.join(" • ") & "</sub>\n\n"

proc formatMermaidChartDirective(config: ChartConfig): string =
  return
    "%%{init: {\"xyChart\": {\"width\": " & $config.width & ", \"height\": " &
    $config.height & "}}}%%"

proc formatMermaidChartxAxis(xAxis: string, xAxisRange: string): string =
  return
    if xAxisRange == "":
      "    x-axis \"" & xAxis & "\""
    else:
      "    x-axis \"" & xAxis & "\" " & xAxisRange

proc formatMermaidChartLines(
    series: seq[(string, seq[float])], precision: int
): string =
  var lines: seq[string]
  for serie in series:
    let lineName = serie[0]
    let values = serie[1].mapIt(formatFloat(it, ffDecimal, precision))
    let line = "    line \"" & lineName & "\" [" & values.join(", ") & "]"
    lines.add(line)

  return lines.join("\n")

proc formatMermaidChart*(
    title, xAxis, yAxis: string,
    series: seq[(string, seq[float])],
    config: ChartConfig,
    xAxisRange: string = "",
    precision: int = 2,
    includeLegend: bool = true,
): string =
  if series.len == 0:
    return ""

  var parts: seq[string] = @[]

  if includeLegend:
    let legend = generateLegend(series.mapIt(it[0]), config.colors)
    parts.add(legend)

  parts.add("```mermaid")
  parts.add(formatMermaidChartDirective(config))
  parts.add("xychart-beta")
  parts.add("    title \"" & title & "\"")
  parts.add(formatMermaidChartxAxis(xAxis, xAxisRange))
  parts.add("    y-axis \"" & yAxis & "\"")
  parts.add(formatMermaidChartLines(series, precision))
  parts.add("```")
  parts.add("")

  return parts.join("\n")

proc formatLatencyChart*(
    data: seq[(int, float, float, float)],
    title: string,
    config: ChartConfig,
    includeLegend: bool = true,
): string =
  if data.len == 0:
    return "No data available for chart generation.\n"

  let minPR = data[0][0]
  let maxPR = data[^1][0]

  let series =
    @[
      ("Min", data.mapIt(it[1])), ("Avg", data.mapIt(it[2])), ("Max", data.mapIt(it[3]))
    ]

  return formatMermaidChart(
    title,
    "PR Number",
    "Latency (ms)",
    series,
    config,
    $minPR & " --> " & $maxPR,
    3,
    includeLegend,
  )

proc formatMultipleCharts*(
    charts: seq[string], legendItems: seq[string], config: ChartConfig
): string =
  if charts.len == 0:
    return "No data available for chart generation.\n"

  var parts: seq[string] = @[]

  # Add single legend for all charts
  if legendItems.len > 0:
    let legend = generateLegend(legendItems, config.colors)
    parts.add(legend)

  # Add all charts
  for chart in charts:
    parts.add(chart)

  return parts.join("\n")

proc convertMB*(bytes: int): float =
  return float(bytes) / 1024.0 / 1024.0

proc calcRateMBps*(curr: float, prev: float, dt: float): float =
  if dt == 0:
    return 0.0
  return (curr - prev) / dt

proc readCsv*[T](path: string, rowHandler: proc(row: CsvRow): T): seq[T] =
  var data: seq[T]
  var p: CsvParser
  p.open(path)
  defer:
    p.close()

  p.readHeaderRow()
  while p.readRow():
    try:
      data.add(rowHandler(p.row))
    except ValueError:
      discard

  return data
