# Add parent directory so `import libp2p` resolves to the root libp2p module.
# Warning/style settings are inherited from the parent config.nims automatically.
switch("path", thisDir() & "/..")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
