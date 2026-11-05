import Feed.Server
import Feed.Selftest

/-! The process: open the database, then run the transport, which calls `Feed.batch`. -/

@[extern "feed_db_open"] opaque dbOpen (path : @& String) : IO Unit
@[extern "feed_transport_run"] opaque runTransport (secret : @& ByteArray) : IO Unit
/-- The workload build.sh profiles the compiler's optimizations on (`runtime/train.c`). -/
@[extern "feed_train_run"] opaque runTrain (dir : @& String) : IO UInt32

def main (args : List String) : IO UInt32 := do
  if let ["--selftest", path] := args then return ← Feed.Selftest.run path
  if let ["--train", dir] := args then return ← runTrain dir
  let some path ← IO.getEnv "SQLITE_PATH" | IO.eprintln "SQLITE_PATH is not set"; return 1
  let some secret ← IO.getEnv "JWT_SECRET" | IO.eprintln "JWT_SECRET is not set"; return 1
  dbOpen path
  runTransport secret.toUTF8
  return 0
