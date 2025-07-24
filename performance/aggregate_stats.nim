import os
from ./utils import Stats, initAggregateStats, processJsonResults, getMarkdownReport

proc main() =
  let outputDir = "performance/output"
  let (results, validNodes) = processJsonResults(outputDir)
  let markdown = getMarkdownReport(results, validNodes)

  echo markdown

  # For GitHub summary
  let summaryPath = getEnv("GITHUB_STEP_SUMMARY", "/tmp/summary.txt")
  writeFile(summaryPath, markdown & "\n")

  # For PR comment
  let commentPath = getEnv("COMMENT_SUMMARY_PATH", "/tmp/summary.txt")
  writeFile(commentPath, markdown & "\n")

main()
