import os
import algorithm
import sequtils
import strformat
import strutils
import tables

let summaryPath = getEnv("GITHUB_STEP_SUMMARY", "step_summary.md")
let repo = getEnv("GITHUB_REPOSITORY", "vacp2p/nim-libp2p")
let branchName = getEnv("BRANCH_NAME", "")
let plotDir = &"subplots/plots/{branchName}"

proc extractTestName(base: string): string =
  let parts = base.split("_")
  return parts[^2]

proc makeImgTag(base: string): string =
  &"<img src=\"https://raw.githubusercontent.com/{repo}/refs/heads/performance_plots/plots/{branchName}/{base}\" width=\"450\" style=\"margin-right:10px;\" />"

var grouped: Table[string, seq[string]]
for path in walkFiles(fmt"{plotDir}/*.png"):
  let base = path.splitPath.tail
  let testName = extractTestName(base)
  let imgTag = makeImgTag(base)

  discard grouped.hasKeyOrPut(testName, @[])
  grouped[testName].add(imgTag)

var summary = &"## Performance Plots for {branchName}\n"
for test in grouped.keys.toSeq().sorted():
  let imgs = grouped[test]
  summary &= &"### {test}\n"
  summary &= imgs.join(" ") & "<br>\n"

writeFile(summaryPath, summary)
echo summary
