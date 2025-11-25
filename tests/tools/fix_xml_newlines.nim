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
    let message = node.attr("message").replace("\n", " | ")
    let details = node.innerText.replace("\n", " | ")

    let combined =
      if details.len > 0:
        details & " | " & message
      else:
        message

    node.attrs = toXmlAttributes()
    node.clear()
    node.add(newText(combined))

  for i in 0 ..< node.len:
    processNode(node[i])

for file in walkFiles("tests/results_*.xml"):
  var xml = parseXml(newFileStream(file, fmRead))
  processNode(xml)

  writeFile(file, $xml)
