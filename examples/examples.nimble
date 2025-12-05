mode = ScriptMode.Verbose

packageName = "examples"
version = "1.0.0"
author = "Status Research & Development GmbH"
description = "Examples for LibP2P implementation"
license = "MIT"

# Dependencies are inherited from parent libp2p.nimble via nimble.paths
# We don't need `requires` here since we run tasks, not build a package

include "../common.nims"

# Add parent directory to search path for libp2p imports
let parentPath = " -p:../"

proc buildSample(filename: string, run = false, extraFlags = "") =
  var excstr =
    nimc & " " & lang & " " & cfg & " " & flags & parentPath & " " & extraFlags
  excstr.add(" " & filename)
  exec excstr
  if run:
    exec "./" & filename.toExe
  rmFile filename.toExe

task examples, "Build and run all examples":
  exec "nimble install -y nimpng"
  exec "nimble install -y nico --passNim=--skipParentCfg"
  buildSample("examples_build", false, "--styleCheck:off")
  buildSample("examples_run", true)

task tutorials, "Generate tutorial markdown files":
  proc tutorialToMd(filename: string) =
    let markdown = gorge "cat " & filename & " | " & nimc & " " & lang &
      " -r --verbosity:0 --hints:off ../tools/markdown_builder.nim "
    writeFile(filename.replace(".nim", ".md"), markdown)

  tutorialToMd("tutorial_1_connect.nim")
  tutorialToMd("tutorial_2_customproto.nim")
  tutorialToMd("tutorial_3_protobuf.nim")
  tutorialToMd("tutorial_4_gossipsub.nim")
  tutorialToMd("circuitrelay.nim")

task website, "Build the website (run from project root)":
  # Generate markdown from tutorials
  tutorialsTask()
  # Build mkdocs site
  withDir "..":
    exec "mkdocs build"
