import algorithm
import json
import sequtils
import strformat
import strutils
import tables
import ../types
import common

const unknownFloat = -1.0

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
    runId: string,
): string =
  var output: seq[string]

  output.add marker & "\n"
  output.add "## 🏁 **Performance Summary**\n"

  let commitUrl = fmt"https://github.com/vacp2p/nim-libp2p/commit/{commitSha}"
  output.add fmt"**Commit:** [`{commitSha}`]({commitUrl})"

  output.add "| Scenario | Nodes | Total messages sent | Total messages received | Latency min (ms) | Latency max (ms) | Latency avg (ms) |"
  output.add "|:---:|:---:|:---:|:---:|:---:|:---:|:---:|"

  var sortedScenarios = toSeq(results.keys)
  sortedScenarios.sort()

  for scenarioName in sortedScenarios:
    let stats = results[scenarioName]
    let nodes = validNodes[scenarioName]
    let emoji =
      if stats.totalReceived != 0 and
          stats.totalReceived == stats.totalSent * (nodes - 1): "✅" else: "❌"
    output.add fmt"| {emoji} {stats.scenarioName} | {nodes} | {stats.totalSent} | {stats.totalReceived} | {stats.latency.minLatencyMs:.3f} | {stats.latency.maxLatencyMs:.3f} | {stats.latency.avgLatencyMs:.3f} |"

  let summaryUrl = fmt"https://github.com/vacp2p/nim-libp2p/actions/runs/{runId}"
  output.add(
    fmt"### 📊 View Container Resources in the [Workflow Summary]({summaryUrl})"
  )

  let markdown = output.join("\n")
  return markdown

proc getCsvFilename*(outputDir: string, prNumber: string): string =
  result = fmt"{outputDir}/pr{prNumber}_latency.csv"

proc getCsvReport*(
    results: Table[string, Stats], validNodes: Table[string, int]
): string =
  var output: seq[string]
  output.add "Scenario,Nodes,TotalSent,TotalReceived,MinLatencyMs,MaxLatencyMs,AvgLatencyMs"

  var sortedScenarios = toSeq(results.keys)
  sortedScenarios.sort()

  for scenarioName in sortedScenarios:
    let stats = results[scenarioName]
    let nodes = validNodes[scenarioName]
    output.add fmt"{stats.scenarioName},{nodes},{stats.totalSent},{stats.totalReceived},{stats.latency.minLatencyMs:.3f},{stats.latency.maxLatencyMs:.3f},{stats.latency.avgLatencyMs:.3f}"
  result = output.join("\n")

proc main() =
  let env = getGitHubEnv()
  let outputDir = env.sharedVolumePath
  let parsedJsons = parseJsonFiles(outputDir)

  let jsonResults = getJsonResults(parsedJsons)
  let (aggregatedResults, validNodes) = aggregateResults(jsonResults)

  # For History
  let csvFilename = getCsvFilename(outputDir, env.prNumber)
  let csvContent = getCsvReport(aggregatedResults, validNodes)
  writeFile(csvFilename, csvContent)

  let markdown = getMarkdownReport(
    aggregatedResults, validNodes, env.marker, env.prHeadSha, env.runId
  )

  echo markdown
  writeGitHubSummary(markdown, env)
  writeGitHubComment(markdown, env)

main()
