import algorithm
import os
import strutils
import ../types

type LatencyData = object
  prNumber: int
  scenario: string
  latency: LatencyStats

proc extractPrNumber(filename: string): int =
  let base = filename.extractFilename
  if base.startsWith("pr") and base.endsWith("_latency.csv"):
    let prStr = base[2 ..^ 13] # Remove "pr" prefix and "_latency.csv" suffix
    try:
      return parseInt(prStr)
    except ValueError:
      return 0
  0

proc readLatencyCsv(path: string): seq[LatencyData] =
  var lines: seq[string]
  var prNumber: int

  try:
    if not fileExists(path):
      echo "Warning: CSV file not found: " & path
      return @[]

    lines = readFile(path).splitLines()
    if lines.len < 2:
      echo "Warning: CSV appears empty: " & path
      return @[]

    prNumber = extractPrNumber(path)
    if prNumber == 0:
      echo "Warning: Invalid PR number in filename: " & path
      return @[]
  except CatchableError as e:
    echo "Warning: Error reading file " & path & ": " & e.msg
    return @[]

  try:
    for i, line in lines:
      if i == 0 or line.len == 0:
        continue
      let cols = line.split(',')
      if cols.len < 7:
        continue

      # Determine if this is a scenario we want to track
      var scenarioType = ""
      if "QUIC" in cols[0]:
        scenarioType = "QUIC"
      elif "Base test" in cols[0] or "TCP" in cols[0]:
        scenarioType = "TCP"

      if scenarioType != "":
        try:
          var data: LatencyData
          data.prNumber = prNumber
          data.scenario = scenarioType
          data.latency.minLatencyMs = parseFloat(cols[4]) # MinLatencyMs
          data.latency.maxLatencyMs = parseFloat(cols[5]) # MaxLatencyMs
          data.latency.avgLatencyMs = parseFloat(cols[6]) # AvgLatencyMs
          result.add(data)
        except ValueError:
          continue
  except CatchableError as e:
    echo "Warning: Error parsing CSV data in " & path & ": " & e.msg
    return @[]

  if result.len == 0:
    echo "Warning: No Base test or QUIC data found in: " & path

proc createLatencyChart(data: seq[LatencyData], title: string): string =
  if data.len == 0:
    return "No data available for chart generation.\n"

  # Create x-axis labels (PR numbers) and y-axis values
  var xAxisLabels: seq[string]
  var minValues: seq[string]
  var avgValues: seq[string]
  var maxValues: seq[string]

  for item in data:
    xAxisLabels.add($item.prNumber)
    minValues.add(formatFloat(item.latency.minLatencyMs, ffDecimal, 3))
    avgValues.add(formatFloat(item.latency.avgLatencyMs, ffDecimal, 3))
    maxValues.add(formatFloat(item.latency.maxLatencyMs, ffDecimal, 3))

  let minPR = data[0].prNumber
  let maxPR = data[^1].prNumber

  let initDirective = "%%{init: {\"xyChart\": {\"width\": 500, \"height\": 200}}}%%\n"
  result = "```mermaid\n" & initDirective & "xychart-beta\n"
  result.add "    title \"" & title & "\"\n"
  result.add "    x-axis \"PR Number\" " & $minPR & " --> " & $maxPR & "\n"
  result.add "    y-axis \"Latency (ms)\"\n"
  result.add "    line \"Min\" [" & minValues.join(", ") & "]\n"
  result.add "    line \"Avg\" [" & avgValues.join(", ") & "]\n"
  result.add "    line \"Max\" [" & maxValues.join(", ") & "]\n"
  result.add "```\n\n"

when isMainModule:
  let latencyDir = getEnv("LATENCY_HISTORY_PATH", "latency_history")
  if not dirExists(latencyDir):
    raiseAssert "Directory not found: " & latencyDir

  var csvFiles: seq[string]
  for kind, path in walkDir(latencyDir):
    if kind == pcFile and path.extractFilename.startsWith("pr") and
        path.toLower.endsWith("_latency.csv"):
      csvFiles.add path

  if csvFiles.len == 0:
    raiseAssert "No pr*_latency.csv files found in " & latencyDir

  var allLatencyData: seq[LatencyData]
  for csvFile in csvFiles:
    try:
      let dataList = readLatencyCsv(csvFile)
      for data in dataList:
        if data.prNumber > 0: # Valid PR number extracted
          allLatencyData.add data
    except CatchableError as e:
      echo "Warning: Failed to process " & csvFile & ": " & e.msg
      continue

  if allLatencyData.len == 0:
    echo "Warning: No valid Base test data found in any CSV files"
    quit(0)

  # Separate TCP and QUIC data
  var tcpData: seq[LatencyData]
  var quicData: seq[LatencyData]

  for data in allLatencyData:
    if "TCP" in data.scenario:
      tcpData.add data
    elif "QUIC" in data.scenario:
      quicData.add data

  # Sort by PR number for chronological order
  tcpData.sort(
    proc(a, b: LatencyData): int =
      cmp(a.prNumber, b.prNumber)
  )
  quicData.sort(
    proc(a, b: LatencyData): int =
      cmp(a.prNumber, b.prNumber)
  )

  # Create charts
  var summary = "### Latency History\n"
  if tcpData.len > 0:
    summary.add createLatencyChart(tcpData, "TCP + Yamux (ms)")
    summary.add "\n"

  if quicData.len > 0:
    summary.add createLatencyChart(quicData, "QUIC (ms)")

  echo summary

  # For GitHub summary
  let summaryPath = getEnv("GITHUB_STEP_SUMMARY", "/tmp/summary.txt")
  let summaryFile = open(summaryPath, fmAppend)
  summaryFile.writeLine(summary)
  summaryFile.close()

  # For PR comment
  let commentPath = getEnv("COMMENT_SUMMARY_PATH", "/tmp/summary.txt")
  let commentFile = open(commentPath, fmAppend)
  commentFile.writeLine(summary)
  commentFile.close()
