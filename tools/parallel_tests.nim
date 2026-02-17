# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Parallel test runner for nim-libp2p.
##
## Scans test source files for `suite "Name"` declarations, partitions them
## across N worker processes, and runs the compiled test binary in parallel
## with suite-level filters (unittest2 glob patterns).
##
## Configuration via environment variables:
##   BINARY    Path to the compiled test binary (default: tests/test_all)
##   WORKERS   Number of parallel workers (default: CPU count)
##   XML_DIR   Directory for per-worker XML reports (default: tests/)

import std/[algorithm, os, osproc, sequtils, strformat, strutils, times]

const
  TestDirs = ["tests/libp2p", "tests/interop", "tests/tools"]
  IgnoreDirs = ["multiformat_exts"]
  SuitePrefix = "suite \""
  DefaultBinary = "tests/test_all"
  DefaultXmlDir = "tests"

proc extractSuiteName(line: string): string =
  ## Extract suite name from a line like: suite "Name":
  let trimmed = line.strip()
  if not trimmed.startsWith(SuitePrefix):
    return ""
  let start = SuitePrefix.len
  let endQuote = trimmed.find('"', start)
  if endQuote < 0:
    return ""
  return trimmed[start ..< endQuote]

proc discoverSuites(): seq[string] =
  ## Scan test source files for suite declarations.
  for dir in TestDirs:
    if not dirExists(dir):
      continue
    for file in walkDirRec(dir):
      let (path, name, ext) = splitFile(file)
      if ext != ".nim" or not name.startsWith("test_") or name == "test_all":
        continue
      if IgnoreDirs.anyIt(path.contains(it)):
        continue
      for line in lines(file):
        let suiteName = extractSuiteName(line)
        if suiteName.len > 0:
          result.add(suiteName)

  # Add the finalCheckTrackers suite (defined in tests/tools/unittest.nim)
  result.add("Final checkTrackers")
  result = result.deduplicate()
  result.sort()

proc partitionSuites(suites: seq[string], workers: int): seq[seq[string]] =
  ## Round-robin partition of sorted suites across workers.
  result = newSeq[seq[string]](workers)
  for i, suite in suites:
    result[i mod workers].add(suite)

proc main() =
  let binary = getEnv("BINARY", DefaultBinary)
  let xmlDir = getEnv("XML_DIR", DefaultXmlDir)
  var workers =
    try:
      parseInt(getEnv("WORKERS", "0"))
    except ValueError:
      0
  if workers <= 0:
    workers = countProcessors()

  if not fileExists(binary):
    echo &"Error: binary not found: {binary}"
    quit(1)

  # Discover suites
  let suites = discoverSuites()
  echo &"Discovered {suites.len} suites"

  if suites.len == 0:
    echo "Error: no suites found"
    quit(1)

  # Adjust workers if we have fewer suites
  let actualWorkers = min(workers, suites.len)
  echo &"Using {actualWorkers} workers"

  # Partition suites
  let partitions = partitionSuites(suites, actualWorkers)

  # Print assignment summary
  for i, partition in partitions:
    echo &"\nWorker {i} ({partition.len} suites):"
    for s in partition:
      echo &"  - {s}"

  echo ""

  # Launch workers
  let startTime = epochTime()
  var processes: seq[(Process, int)] = @[]

  for i, partition in partitions:
    var args: seq[string] = @[]
    for s in partition:
      args.add(&"{s}::*")
    args.add("--console")
    args.add("--output-level=VERBOSE")
    args.add(&"--xml:{xmlDir}/results_worker_{i}.xml")

    let process = startProcess(
      binary,
      args = args,
      options = {poParentStreams}
    )
    processes.add((process, i))

  # Wait for all workers
  var failures: seq[int] = @[]
  for (process, i) in processes:
    let exitCode = waitForExit(process)
    if exitCode != 0:
      failures.add(i)
      echo &"\nWorker {i} FAILED (exit code: {exitCode})"
    else:
      echo &"\nWorker {i} OK"
    close(process)

  let elapsed = epochTime() - startTime

  # Summary
  echo &"\n{'='.repeat(40)}"
  echo &"Parallel test run complete in {elapsed:.1f}s"
  echo &"Workers: {actualWorkers}, Suites: {suites.len}"
  if failures.len > 0:
    echo &"FAILED workers: {failures}"
    quit(1)
  else:
    echo "All workers passed"

when isMainModule:
  main()
