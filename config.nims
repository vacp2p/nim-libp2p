# to allow locking
if dirExists("nimbledeps/pkgs"):
  switch("NimblePath", "nimbledeps/pkgs")
if dirExists("nimbledeps/pkgs2"):
  switch("NimblePath", "nimbledeps/pkgs2")

switch("warning", "CaseTransition:off")
switch("warning", "ObservableStores:off")
switch("warning", "LockLevel:off")
--styleCheck:
  usages
switch("warningAsError", "UseBase:on")
--styleCheck:
  error

# Avoid some rare stack corruption while using exceptions with a SEH-enabled
# toolchain: https://github.com/status-im/nimbus-eth2/issues/3121
if defined(windows) and not defined(vcc):
  --define:
    nimRawSetjmp

# begin Nimble config (version 1)
when fileExists("nimble.paths"):
  include "nimble.paths"
# end Nimble config
