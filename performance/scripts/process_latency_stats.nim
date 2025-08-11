import json
import os
import sequtils
import strutils
import strformat
import tables
import ../types

const unknownFloat = -1.0

proc parseJsonFiles*(outputDir: string): seq[JsonNode] =
  var jsons: seq[JsonNode]

  for kind, path in walkDir(outputDir):
    if kind == pcFile and path.endsWith(".json"):
      let content = readFile(path)
      let json = parseJson(content)

      jsons.add(json)

  return jsons

proc extractStats(scenario: JsonNode): Stats =
  Stats(
    scenarioName: scenario["scenarioName"].getStr(""),
    totalSent: scenario["totalSent"].getInt(0),
    totalReceived: scenario["totalReceived"].getInt(0),
    latency: LatencyStats(
      minLatencyMs: scenario["minLatencyMs"].getStr($unknownFloat).parseFloat(),
      maxLatencyMs: scenario["maxLatencyMs"].getStr($unknownFloat).parseFloat(),
      avgLatencyMs: scenario["avgLatencyMs"].getStr($unknownFloat).parseFloat(),
    ),
  )

proc getJsonResults*(jsons: seq[JsonNode]): seq[Table[string, Stats]] =
  jsons.mapIt(
    it["results"]
    .getElems(@[])
    .mapIt(it.extractStats())
    .mapIt((it.scenarioName, it)).toTable
  )

proc aggregateResults*(
    jsonResults: seq[Table[string, Stats]]
): (Table[string, Stats], Table[string, int]) =
  var aggragated: Table[string, Stats]
  var validNodes: Table[string, int]

  for jsonResult in jsonResults:
    for scenarioName, stats in jsonResult.pairs:
      let startingStats = Stats(
        scenarioName: scenarioName,
        totalSent: 0,
        totalReceived: 0,
        latency: LatencyStats(minLatencyMs: Inf, maxLatencyMs: 0, avgLatencyMs: 0),
      )
      discard aggragated.hasKeyOrPut(scenarioName, startingStats)
      discard validNodes.hasKeyOrPut(scenarioName, 0)

      aggragated[scenarioName].totalSent += stats.totalSent
      aggragated[scenarioName].totalReceived += stats.totalReceived

      let minL = stats.latency.minLatencyMs
      let maxL = stats.latency.maxLatencyMs
      let avgL = stats.latency.avgLatencyMs
      if minL != unknownFloat and maxL != unknownFloat and avgL != unknownFloat:
        if minL < aggragated[scenarioName].latency.minLatencyMs:
          aggragated[scenarioName].latency.minLatencyMs = minL

        if maxL > aggragated[scenarioName].latency.maxLatencyMs:
          aggragated[scenarioName].latency.maxLatencyMs = maxL

        aggragated[scenarioName].latency.avgLatencyMs += avgL
          # used to store sum of averages

        validNodes[scenarioName] += 1

  for scenarioName, stats in aggragated.mpairs:
    let nodes = validNodes[scenarioName]
    let globalAvgLatency = stats.latency.avgLatencyMs / float(nodes)
    stats.latency.avgLatencyMs = globalAvgLatency

  return (aggragated, validNodes)

proc getMarkdownReport*(
    results: Table[string, Stats],
    validNodes: Table[string, int],
    marker: string,
    commitSha: string,
): string =
  var output: seq[string]

  output.add marker & "\n"
  output.add "# 🏁 **Performance Summary**\n"

  let commitUrl = fmt"https://github.com/vacp2p/nim-libp2p/commit/{commitSha}"
  output.add fmt"**Commit:** [`{commitSha}`]({commitUrl})"

  output.add "| Scenario | Nodes | Total messages sent | Total messages received | Latency min (ms) | Latency max (ms) | Latency avg (ms) |"
  output.add "|:---:|:---:|:---:|:---:|:---:|:---:|:---:|"

  for scenarioName, stats in results.pairs:
    let nodes = validNodes[scenarioName]
    output.add fmt"| {stats.scenarioName} | {nodes} | {stats.totalSent} | {stats.totalReceived} | {stats.latency.minLatencyMs:.3f} | {stats.latency.maxLatencyMs:.3f} | {stats.latency.avgLatencyMs:.3f} |"

  let runId = getEnv("GITHUB_RUN_ID", "")
  let summaryUrl = fmt"https://github.com/vacp2p/nim-libp2p/actions/runs/{runId}"
  output.add(
    fmt"### 📊 View full Container Resources stats in the [Workflow Summary]({summaryUrl})"
  )

  let markdown = output.join("\n")
  return markdown

proc main() =
  let outputDir = "performance/output"
  let parsedJsons = parseJsonFiles(outputDir)

  let jsonResults = getJsonResults(parsedJsons)
  let (aggregatedResults, validNodes) = aggregateResults(jsonResults)

  let marker = getEnv("MARKER", "<!-- marker -->")
  let commitSha = getEnv("PR_HEAD_SHA", getEnv("GITHUB_SHA", "unknown"))
  let markdown = getMarkdownReport(aggregatedResults, validNodes, marker, commitSha)

  echo markdown

  # For GitHub summary
  let summaryPath = getEnv("GITHUB_STEP_SUMMARY", "/tmp/summary.txt")
  writeFile(summaryPath, markdown & "\n")

  # For PR comment
  let commentPath = getEnv("COMMENT_SUMMARY_PATH", "/tmp/summary.txt")
  writeFile(commentPath, markdown & "\n")

main()
