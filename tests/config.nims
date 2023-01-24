import ../config.nims
import strutils

--threads:on
--d:metrics
--d:withoutPCRE
--d:libp2p_agents_metrics
--d:libp2p_protobuf_metrics
--d:libp2p_network_protocols_metrics
--d:libp2p_mplex_metrics

# Only add chronicles param if the
# user didn't specify any
var hasChroniclesParam = false
for param in 0..<paramCount():
  if "chronicles" in paramStr(param):
    hasChroniclesParam = true

if not hasChroniclesParam:
  switch("import", "stublogger")
  switch("define", "chronicles_sinks=textlines[stdout],json[dynamic]")
  switch("define", "chronicles_log_level=TRACE")
  switch("define", "chronicles_runtime_filtering=TRUE")
