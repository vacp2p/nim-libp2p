# to allow locking
if dirExists("nimbledeps/pkgs"):
  switch("NimblePath", "nimbledeps/pkgs")

when (NimMajor, NimMinor) > (1, 2):
  switch("hint", "XCannotRaiseY:off")
# begin Nimble config (version 1)
when fileExists("nimble.paths"):
  include "nimble.paths"
# end Nimble config
