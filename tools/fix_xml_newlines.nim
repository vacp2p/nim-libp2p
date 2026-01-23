# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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
