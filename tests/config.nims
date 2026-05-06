import ../config.nims
import strutils, os

--threads:
  on
--d:
  metrics
--d:
  withoutPCRE
--d:
  libp2p_agents_metrics
--d:
  libp2p_protobuf_metrics
--d:
  libp2p_network_protocols_metrics
--d:
  libp2p_mplex_metrics
--d:
  unittestPrintTime

# Only add chronicles param if the
# user didn't specify any
var hasChroniclesParam = false
for param in 0 ..< system.paramCount():
  if "chronicles" in system.paramStr(param):
    hasChroniclesParam = true

if hasChroniclesParam:
  echo "Since you specified chronicles params, TRACE won't be tested!"
else:
  let modulePath = currentSourcePath.parentDir / "stublogger"
  switch("import", modulePath)
  switch("define", "chronicles_sinks=textlines[stdout],json[dynamic]")
  switch("define", "chronicles_log_level=TRACE")
  switch("define", "chronicles_runtime_filtering=TRUE")
