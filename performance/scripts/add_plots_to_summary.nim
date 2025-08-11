import os
import algorithm
import sequtils
import strformat
import strutils
import tables

proc getImgUrlBase(repo: string, publishBranchName: string, plotsPath: string): string =
  &"https://raw.githubusercontent.com/{repo}/refs/heads/{publishBranchName}/{plotsPath}"

proc extractTestName(base: string): string =
  let parts = base.split("_")
  if parts.len >= 2:
    parts[^2]
  else:
    base

proc makeImgTag(imgUrl: string, width: int): string =
  &"<img src=\"{imgUrl}\" width=\"{width}\" style=\"margin-right:10px;\" />"

proc prepareLatencyHistoryImage(
    imgUrlBase: string, latencyHistoryFilePath: string, width: int = 600
): string =
  let latencyImgUrl = &"{imgUrlBase}/{latencyHistoryFilePath}"
  makeImgTag(latencyImgUrl, width)

proc prepareDockerStatsImages(
    plotDir: string, imgUrlBase: string, branchName: string, width: int = 450
): Table[string, seq[string]] =
  ## Groups docker stats plot images by test name and returns HTML <img> tags.
  var grouped: Table[string, seq[string]]

  for path in walkFiles(&"{plotDir}/*.png"):
    let plotFile = path.splitPath.tail
    let testName = extractTestName(plotFile)
    let imgUrl = &"{imgUrlBase}/{branchName}/{plotFile}"
    let imgTag = makeImgTag(imgUrl, width)
    discard grouped.hasKeyOrPut(testName, @[])
    grouped[testName].add(imgTag)

  grouped

proc buildSummary(
    plotDir: string,
    repo: string,
    branchName: string,
    publishBranchName: string,
    plotsPath: string,
    latencyHistoryFilePath: string,
): string =
  let imgUrlBase = getImgUrlBase(repo, publishBranchName, plotsPath)

  var buf: seq[string]

  # Latency History section
  buf.add("## Latency History")
  buf.add(prepareLatencyHistoryImage(imgUrlBase, latencyHistoryFilePath) & "<br>")
  buf.add("")

  # Performance Plots section
  let grouped = prepareDockerStatsImages(plotDir, imgUrlBase, branchName)
  buf.add(&"## Performance Plots for {branchName}")
  for test in grouped.keys.toSeq().sorted():
    let imgs = grouped[test]
    buf.add(&"### {test}")
    buf.add(imgs.join(" ") & "<br>")

  buf.join("\n")

proc main() =
  let summaryPath = getEnv("GITHUB_STEP_SUMMARY", "/tmp/step_summary.md")
  let repo = getEnv("GITHUB_REPOSITORY", "vacp2p/nim-libp2p")
  let branchName = getEnv("BRANCH_NAME", "")
  let publishBranchName = getEnv("PUBLISH_BRANCH_NAME", "performance_plots")
  let plotsPath = getEnv("PLOTS_PATH", "plots")
  let latencyHistoryFilePath =
    getEnv("LATENCY_HISTORY_PLOT_FILENAME", "latency_history_all_scenarios.png")
  let checkoutSubfolder = getEnv("CHECKOUT_SUBFOLDER", "subplots")
  let plotDir = &"{checkoutSubfolder}/{plotsPath}/{branchName}"

  let summary = buildSummary(
    plotDir, repo, branchName, publishBranchName, plotsPath, latencyHistoryFilePath
  )
  writeFile(summaryPath, summary)
  echo summary

main()
