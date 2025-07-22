import os, strutils, json, strformat

proc getEnvOrDefault(key, default: string): string =
  result = getEnv(key)
  if result.len == 0:
    result = default

proc main() =
  let outputDir = os.joinPath(os.getAppDir(), "output")
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
      let sent =
        if stats.hasKey("totalSent"):
          stats["totalSent"].getInt
        else:
          0
      let received =
        if stats.hasKey("totalReceived"):
          stats["totalReceived"].getInt
        else:
          0
      let minL =
        if stats.hasKey("minLatency"):
          stats["minLatency"].getStr.parseFloat
        else:
          0.0
      let maxL =
        if stats.hasKey("maxLatency"):
          stats["maxLatency"].getStr.parseFloat
        else:
          0.0
      let avgL =
        if stats.hasKey("avgLatency"):
          stats["avgLatency"].getStr.parseFloat
        else:
          0.0
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
