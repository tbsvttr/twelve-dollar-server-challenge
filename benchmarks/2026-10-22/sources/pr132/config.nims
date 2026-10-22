# Project-wide Nim configuration.
#
# `src/sqlite3.nim` includes the vendored header via `header: "vendor/sqlite3.h"`.
# That resolves only if the submission root is on the C include path, so inject it
# here for EVERY compile (the server build and the unit tests alike). build.sh
# passes the same flag; a duplicate -I is harmless.
import std/os
let root = currentSourcePath().parentDir
switch("passC", "-I" & root)

# `src/jwt.nim` imports nimcrypto for HMAC-SHA256. It is vendored by build.sh
# (pinned download, see build.sh) so the build never depends on a user Nimble
# directory. Add its path for EVERY compile (server, io_uring transport, tests).
let nimcrypto = root / "vendor" / "nimcrypto"
if dirExists(nimcrypto):
  switch("path", nimcrypto)
