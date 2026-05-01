# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This tool downloads the multicodec table CSV from the multiformats/multicodec
## repository and generates a Nim include file with the codec list used in
## libp2p/multicodec.nim.
##
## Usage: nim c -r tools/gen_multicodec.nim
## Or via nimble: nimble gen_multicodec

import httpclient, strutils

const
  CsvUrl = "https://raw.githubusercontent.com/multiformats/multicodec/master/table.csv"
  OutputFile = "libp2p/multicodec_table.nim"

proc toNimHex(hexStr: string): string =
  ## Convert a hex string (e.g. "0x1a") to a Nim-style uppercase hex literal (e.g. "0x1A").
  let prefix =
    if hexStr.len > 2:
      hexStr[0 .. 1]
    else:
      ""
  if prefix == "0x" or prefix == "0X":
    "0x" & hexStr[2 ..^ 1].toUpperAscii()
  else:
    hexStr

proc generateCodecList(csvContent: string): string =
  var lines: seq[string]
  lines.add("# This file is auto-generated from the multicodec table CSV at:")
  lines.add("# https://github.com/multiformats/multicodec/blob/master/table.csv")
  lines.add("#")
  lines.add("# DO NOT EDIT MANUALLY. Run `nimble gen_multicodec` to regenerate.")
  lines.add("")
  lines.add("const MultiCodecList = [")

  for line in csvContent.splitLines():
    let trimmed = line.strip()

    # Skip empty lines and the header line
    if trimmed == "" or trimmed.startsWith("name,"):
      continue

    # CSV columns: name, tag, code, status, description
    let parts = trimmed.split(",")
    if parts.len < 3:
      continue

    let name = parts[0].strip()
    let code = parts[2].strip()

    if name == "" or code == "" or not (code.startsWith("0x") or code.startsWith("0X")):
      continue

    lines.add("  (\"" & name & "\", " & toNimHex(code) & "),")

  lines.add("]")
  return lines.join("\n") & "\n"

proc main() =
  echo "Downloading multicodec table from: ", CsvUrl
  let client = newHttpClient()
  defer:
    client.close()
  let csv = client.getContent(CsvUrl)
  let content = generateCodecList(csv)
  writeFile(OutputFile, content)
  echo "Generated: ", OutputFile

main()
