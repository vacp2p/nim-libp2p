# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[os, xmlparser, xmltree, streams, strutils]

proc processNode(node: var XmlNode) =
  if node.kind == xnElement and node.tag == "failure":
    let message = node.attr("message")
    let details = node.innerText.replace("\n", " | ")

    node.clear()
    node.add(newText(details & " | " & message))

  for i in 0 ..< node.len:
    processNode(node[i])

for file in walkFiles("tests/results_*.xml"):
  var xml = parseXml(newFileStream(file, fmRead))
  processNode(xml)

  writeFile(file, $xml)
  echo readFile(file)
