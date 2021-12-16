import os
import strscans
import algorithm
import tables
import sequtils
import strutils
import json
import osproc

const PinFile = ".pinned"
removeDir("nimbledeps")
createDir("nimbledeps")
discard execCmd("nimble install -dy")

var allDeps: Table[string, string]
for (_, dependency) in walkDir("nimbledeps/pkgs"):
  let fileContent = parseJson(readFile(dependency & "/nimblemeta.json"))
  let url = fileContent.getOrDefault("url").getStr("")
  var version = fileContent.getOrDefault("vcsRevision").getStr("")
  var packageName = dependency.split('/')[^1].split('-')[0]

  if version.len == 0:
    version = execCmdEx("git ls-remote " & url).output.split()[0]

  if version.len > 0 and url.len > 0:
    let fullPackage = url & "@#" & version
    if packageName in allDeps and allDeps[packageName] != fullPackage:
      echo "Warning: duplicate package " & packageName & ":"
      echo allDeps[packageName]
      echo fullPackage
      echo ""
    allDeps[packageName] = fullPackage
  else:
    echo "Failed to get url & version for ", dependency

let asString = toSeq(allDeps.pairs).mapIt(it[0] & ";" & it[1]).sorted().join("\n")
writeFile(PinFile, asString)
echo asString
