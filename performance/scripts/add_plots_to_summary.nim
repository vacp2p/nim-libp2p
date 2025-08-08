import os
import algorithm
import sequtils
import strformat
import strutils
import tables

proc getImgUrlBase(repo: string, plotsBranchName: string, plotsPath: string): string =
  &"https://raw.githubusercontent.com/{repo}/refs/heads/{plotsBranchName}/{plotsPath}"

proc extractTestName(base: string): string =
  let parts = base.split("_")
  return parts[^2]

proc makeImgTag(imgUrl: string, width: int): string =
  &"<img src=\"{imgUrl}\" width=\"{width}\" style=\"margin-right:10px;\" />"

proc prepareLatencyHistoryImage(
    repo: string,
    plotsBranchName: string,
    plotsPath: string,
    latencyHistoryFilePath: string,
): string =
  let latencyImgUrlBase = getImgUrlBase(repo, plotsBranchName, plotsPath)
  let latencyImgUrl = &"{latencyImgUrlBase}/{latencyHistoryFilePath}"
  return makeImgTag(latencyImgUrl, 600)

proc prepareDockerStatsImages(
    plotDir: string,
    repo: string,
    branchName: string,
    plotsBranchName: string,
    plotsPath: string,
): Table[string, seq[string]] =
  var grouped: Table[string, seq[string]]
  for path in walkFiles(fmt"{plotDir}/*.png"):
    let plotFile = path.splitPath.tail
    let testName = extractTestName(plotFile)
    let imgUrlBase = getImgUrlBase(repo, plotsBranchName, plotsPath)
    let imgUrl = &"{imgUrlBase}/{branchName}/{plotFile}"
    let imgTag = makeImgTag(imgUrl, 450)
    discard grouped.hasKeyOrPut(testName, @[])
    grouped[testName].add(imgTag)
  return grouped

proc buildSummary(
    plotDir: string,
    repo: string,
    branchName: string,
    plotsBranchName: string,
    plotsPath: string,
    latencyHistoryFilePath: string,
): string =
  var summary = ""

  # Add Latency History section first
  summary &= "## Latency History\n"
  let latencyImgTag =
    prepareLatencyHistoryImage(repo, plotsBranchName, plotsPath, latencyHistoryFilePath)
  summary &= latencyImgTag & "<br>\n\n"

  # Then add Performance Plots section
  let grouped =
    prepareDockerStatsImages(plotDir, repo, branchName, plotsBranchName, plotsPath)
  summary &= &"## Performance Plots for {branchName}\n"
  for test in grouped.keys.toSeq().sorted():
    let imgs = grouped[test]
    summary &= &"### {test}\n"
    summary &= imgs.join(" ") & "<br>\n"

  return summary

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
