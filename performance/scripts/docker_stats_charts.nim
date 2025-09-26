import algorithm
import os
import sequtils
import strformat
import strutils
import tables

type CsvData = object
  timestamps: seq[float]
  cpu: seq[float]
  memory: seq[float]
  downloadRate: seq[float]
  uploadRate: seq[float]
  downloadTotal: seq[float]
  uploadTotal: seq[float]

proc readCsv(path: string): CsvData =
  if not fileExists(path):
    quit "CSV file not found: " & path, 1
  let lines = readFile(path).splitLines()
  if lines.len < 2:
    quit "CSV appears empty", 1

  for i, line in lines:
    if i == 0 or line.len == 0:
      continue
    let cols = line.split(',')
    if cols.len < 7:
      continue

    try:
      result.timestamps.add parseFloat(cols[0])
      result.cpu.add parseFloat(cols[1])
      result.memory.add parseFloat(cols[2])
      result.downloadRate.add parseFloat(cols[3])
      result.uploadRate.add parseFloat(cols[4])
      result.downloadTotal.add parseFloat(cols[5])
      result.uploadTotal.add parseFloat(cols[6])
    except ValueError:
      continue

proc formatValues(vals: seq[float], precision: int = 2): string =
  "[" & vals.mapIt(formatFloat(it, ffDecimal, precision)).join(", ") & "]"

proc createChart(
    title, xAxis, yAxis: string,
    series: seq[(string, seq[float])],
    width: int = 450,
    height: int = 300,
): string =
  let initDirective =
    "%%{init: {\"xyChart\": {\"width\": " & $width & ", \"height\": " & $height &
    "}}}%%\n"
  result = "```mermaid\n" & initDirective & "xychart-beta\n"
  result.add "    title \"" & title & "\"\n"
  result.add "    x-axis \"" & xAxis & "\"\n"
  result.add "    y-axis \"" & yAxis & "\"\n"

  for (name, data) in series:
    if data.len > 0:
      result.add "    line \"" & name & "\" " & formatValues(data) & "\n"

  result.add "```\n\n"

proc extractBaseName(filename: string): string =
  var base = filename.extractFilename
  if base.endsWith(".csv"):
    base = base[0 ..^ 5]
  if base.startsWith("docker_stats_"):
    base = base[13 ..^ 1]

  # Remove trailing _<digits> to group runs
  let lastUnderscore = base.rfind('_')
  if lastUnderscore > 0:
    let suffix = base[lastUnderscore + 1 ..^ 1]
    if suffix.allCharsInSet({'0' .. '9'}):
      return base[0 .. lastUnderscore - 1]
  base

proc extractRunName(filename: string): string =
  var name = filename.extractFilename
  if name.endsWith(".csv"):
    name = name[0 ..^ 5]
  if name.startsWith("docker_stats_"):
    name = name[13 ..^ 1]
  name

when isMainModule:
  let outDir = "performance" / "output"
  if not dirExists(outDir):
    quit "Directory not found: " & outDir, 1

  var csvFiles: seq[string]
  for kind, path in walkDir(outDir):
    if kind == pcFile and path.extractFilename.startsWith("docker_stats") and
        path.toLower.endsWith(".csv"):
      csvFiles.add path

  if csvFiles.len == 0:
    quit "No docker_stats*.csv files found in " & outDir, 1

  sort(csvFiles)

  type TestRun = object
    name: string
    data: CsvData

  var testGroups: Table[string, seq[TestRun]]
  for csvFile in csvFiles:
    let data = readCsv(csvFile)
    if data.timestamps.len == 0:
      continue

    let groupName = extractBaseName(csvFile)
    let runName = extractRunName(csvFile)

    if not testGroups.hasKey(groupName):
      testGroups[groupName] = @[]

    testGroups[groupName].add TestRun(name: runName, data: data)

  # Generate charts for each test group
  var groupNames = testGroups.keys.toSeq
  groupNames.sort

  var buf: seq[string]

  for groupName in groupNames:
    let runs = testGroups[groupName]
    if runs.len == 0:
      continue

    buf.add(fmt"### {groupName}")

    # CPU Chart
    var cpuSeries: seq[(string, seq[float])]
    for run in runs:
      if run.data.cpu.len > 0:
        cpuSeries.add((run.name, run.data.cpu))
    if cpuSeries.len > 0:
      buf.add(
        createChart("CPU % vs Time - " & groupName, "Time (s)", "CPU %", cpuSeries)
      )

    # Memory Chart
    var memSeries: seq[(string, seq[float])]
    for run in runs:
      if run.data.memory.len > 0:
        memSeries.add((run.name, run.data.memory))
    if memSeries.len > 0:
      buf.add(
        createChart(
          "Memory Usage (MB) - " & groupName, "Time (s)", "Memory (MB)", memSeries
        )
      )

    # Network Throughput Chart
    var netSeries: seq[(string, seq[float])]
    for run in runs:
      if run.data.downloadRate.len > 0:
        netSeries.add((run.name & " download", run.data.downloadRate))
      if run.data.uploadRate.len > 0:
        netSeries.add((run.name & " upload", run.data.uploadRate))
    if netSeries.len > 0:
      buf.add(
        createChart(
          "Network Throughput (MB/s) - " & groupName, "Time (s)", "MB/s", netSeries
        )
      )

    # Total Network Data Chart
    var totalSeries: seq[(string, seq[float])]
    for run in runs:
      if run.data.downloadTotal.len > 0:
        totalSeries.add((run.name & " download", run.data.downloadTotal))
      if run.data.uploadTotal.len > 0:
        totalSeries.add((run.name & " upload", run.data.uploadTotal))
    if totalSeries.len > 0:
      buf.add(
        createChart(
          "Total Network Data (MB) - " & groupName, "Time (s)", "MB", totalSeries
        )
      )

  # Append to GitHub step summary if available
  let summary = buf.join("\n")
  echo summary
  let summaryPath = getEnv("GITHUB_STEP_SUMMARY", "")
  if summaryPath.len > 0:
    try:
      writeFile(summaryPath, summary)
    except CatchableError as e:
      stderr.writeLine "Failed to write to GITHUB_STEP_SUMMARY: " & e.msg
