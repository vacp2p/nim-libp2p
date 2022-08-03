# to allow locking
if dirExists("nimbledeps/pkgs"):
  switch("NimblePath", "nimbledeps/pkgs")

# begin Nimble config (version 1)
when fileExists("nimble.paths"):
  include "nimble.paths"
# end Nimble config
