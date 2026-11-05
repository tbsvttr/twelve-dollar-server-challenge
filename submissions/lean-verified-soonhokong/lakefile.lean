import Lake
open Lake DSL

package feed where
  moreLeancArgs := #["-O3", "-march=native", "-fno-plt"]

lean_lib Feed

/-- `Main` as a module of the package. build.sh compiles the C runtime (SQLite, storage primitives,
byte leaves, io_uring transport) and links `bin/server` from the C that `lake build` emits. -/
@[default_target]
lean_exe server where
  root := `Main
  moreLinkArgs := #["build/libfeedrt.a", "-lpthread", "-lm", "-ldl"]
