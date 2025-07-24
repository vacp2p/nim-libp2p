import os
from ./utils import parseJsonFiles, getJsonResults, aggregateResults, getMarkdownReport

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
