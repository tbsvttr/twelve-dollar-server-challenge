import UorEmit.Emit

-- The module returns one archive: each file is its path, a newline, its bytes and a zero byte. Lean does the only I/O here.

partial def find (data : ByteArray) (byte : UInt8) (start : Nat) : Nat :=
  if start >= data.size then data.size
  else if data[start]! == byte then start
  else find data byte (start + 1)

partial def writeFiles (data : ByteArray) (start : Nat) (directory : System.FilePath) : IO Unit := do
  if start >= data.size then return
  let line := find data 10 start
  let stop := find data 0 (line + 1)
  let path := directory / String.fromUTF8! (data.extract start line)
  if let some parent := path.parent then IO.FS.createDirAll parent
  IO.FS.writeBinFile path (data.extract (line + 1) stop)
  writeFiles data (stop + 1) directory

def main (arguments : List String) : IO Unit :=
  writeFiles (UorEmit.Emit.emitSource ByteArray.empty) 0 (arguments.headD "generated")
