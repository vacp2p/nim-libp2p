import os, strutils, json, strformat

proc getEnvOrDefault(key, default: string): string =
  result = getEnv(key)
  if result.len == 0:
    result = default

proc main() =
  let outputDir = "performance/output"
  var totalSent = 0
  var totalReceived = 0
  var minLatency = Inf
  var maxLatency = 0.0
  var sumAvgLatency = 0.0
  var validNodes = 0

  for kind, path in walkDir(outputDir):
    if kind == pcFile and path.endsWith(".json"):
      let content = readFile(path)
      let stats = parseJson(content)
      proc getIntOr(stats: JsonNode, key: string, default: int): int =
        if stats.hasKey(key):
          stats[key].getInt
        else:
          default

      proc getFloatOr(stats: JsonNode, key: string, default: float): float =
        if stats.hasKey(key):
          stats[key].getStr.parseFloat
        else:
          default

      let sent = getIntOr(stats, "totalSent", 0)
      let received = getIntOr(stats, "totalReceived", 0)
      let minL = getFloatOr(stats, "minLatency", 0.0)
      let maxL = getFloatOr(stats, "maxLatency", 0.0)
      let avgL = getFloatOr(stats, "avgLatency", 0.0)
      totalSent += sent
      totalReceived += received
      if minL > 0.0 or maxL > 0.0 or avgL > 0.0:
        if minL < minLatency:
          minLatency = minL
        if maxL > maxLatency:
          maxLatency = maxL
        sumAvgLatency += avgL
        validNodes += 1

  let commitSha =
    getEnvOrDefault("PR_HEAD_SHA", getEnvOrDefault("GITHUB_SHA", "unknown"))
  var output: seq[string]
  output.add "<!-- perf-summary-marker -->\n"
  output.add "# 🏁 **Performance Summary**\n"
  output.add fmt"**Commit:** `{commitSha}`  "
  output.add fmt"**Nodes:** `{validNodes}`  "
  output.add fmt"**Total messages sent:** `{totalSent}`  "
  output.add fmt"**Total messages received:** `{totalReceived}`  \n"
  output.add "| Latency (ms) | Min | Max | Avg |"
  output.add "|:---:|:---:|:---:|:---:|"
  if validNodes > 0:
    let globalAvgLatency = sumAvgLatency / float(validNodes)
    output.add fmt"| | {minLatency:.3f} | {maxLatency:.3f} | {globalAvgLatency:.3f} |"
  else:
    output.add "| | 0.000 | 0.000 | 0.000 | (no valid latency data)"
  let markdown = output.join("\n")
  echo markdown
  # For GitHub summary
  let summaryPath = getEnvOrDefault("GITHUB_STEP_SUMMARY", "/tmp/summary.txt")
  writeFile(summaryPath, markdown & "\n")
  # For PR comment
  writeFile("/tmp/perf-summary.md", markdown & "\n")

when isMainModule:
  main()
