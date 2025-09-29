import json
import os
import sequtils
import strutils
import ../types

proc findFilesByPattern*(dir: string, patterns: seq[string]): seq[string] =
  var files: seq[string] = @[]
  for entry in walkDir(dir):
    if entry.kind == pcFile:
      for pattern in patterns:
        if pattern in entry.path or entry.path.endsWith(pattern):
          files.add(entry.path)
          break
  return files

proc findJsonFiles*(dir: string): seq[string] =
  findFilesByPattern(dir, @[".json"])

proc findCsvFiles*(dir: string, prefix: string = ""): seq[string] =
  let allCsvFiles = findFilesByPattern(dir, @[".csv"])
  let files =
    if prefix == "":
      allCsvFiles
    else:
      allCsvFiles.filterIt(prefix in it)

  return files

proc findLogFiles*(dir: string, prefix: string): seq[string] =
  let allLogFiles = findFilesByPattern(dir, @[".log"])
  return allLogFiles.filterIt(prefix in it)

proc readCsvLines*(path: string): seq[seq[string]] =
  if not fileExists(path):
    return @[]

  let lines = readFile(path).splitLines()
  var output: seq[seq[string]] = @[]

  for line in lines:
    if line.len > 0:
      output.add(line.split(','))

  return output

proc parseJsonFiles*(outputDir: string): seq[JsonNode] =
  var jsons: seq[JsonNode]

  for kind, path in walkDir(outputDir):
    if kind == pcFile and path.endsWith(".json"):
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
  )

proc writeGitHubOutputs*(
    content: string, env: GitHubEnv, toJobSummary: bool, toComment: bool
) =
  if toJobSummary:
    let file = open(env.stepSummary, fmAppend)
    file.write(content & "\n")
    file.close()

  if toComment:
    let file = open(env.commentSummaryPath, fmAppend)
    file.write(content & "\n")
    file.close()

proc extractPrNumber*(filename: string): int =
  let base = filename.extractFilename
  if base.startsWith("pr") and base.endsWith("_latency.csv"):
    let prString = base[2 .. ^13]
    try:
      return parseInt(prString)
    except ValueError:
      return 0
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

  if not keepSuffix:
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

  let values = series
    .mapIt(
      "    line \"" & it[0] & "\" [" &
        it[1].mapIt(formatFloat(it, ffDecimal, precision)).join(", ") & "]"
    )
    .join("\n")

  let xAxisLine =
    if xAxisRange == "":
      "    x-axis \"" & xAxis & "\""
    else:
      "    x-axis \"" & xAxis & "\" " & xAxisRange

  var parts: seq[string] = @[]

  if includeLegend:
    let legend = generateLegend(series.mapIt(it[0]), config.colors)
    parts.add(legend)

  parts.add("```mermaid")
  parts.add(
    "%%{init: {\"xyChart\": {\"width\": " & $config.width & ", \"height\": " &
      $config.height & "}}}%%"
  )
  parts.add("xychart-beta")
  parts.add("    title \"" & title & "\"")
  parts.add(xAxisLine)
  parts.add("    y-axis \"" & yAxis & "\"")
  parts.add(values)
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

const defaultColors* = @["🔵", "🟢", "🔴", "🟠"]

proc getDefaultChartConfig*(): ChartConfig =
  ChartConfig(colors: defaultColors, width: 450, height: 300)

proc convertMB*(bytes: int): float =
  return float(bytes) / 1024.0 / 1024.0

proc calcRateMBps*(curr: float, prev: float, dt: float): float =
  if dt == 0:
    return 0.0
  return (curr - prev) / dt
