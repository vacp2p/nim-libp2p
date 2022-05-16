# to allow locking
if dirExists("nimbledeps/pkgs"):
  switch("NimblePath", "nimbledeps/pkgs")

when (NimMajor, NimMinor) > (1, 2):
  switch("hint", "XCannotRaiseY:off")