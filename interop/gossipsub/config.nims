# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Send chronicles logs to stderr so stdout is reserved for structured JSON output
switch("define", "chronicles_sinks=textlines[stderr]")
switch("define", "chronicles_log_level=INFO")
