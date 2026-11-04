# frozen_string_literal: true

# Builds the Lite extension with the pinned SQLite amalgamation compiled in. SQLITE_SRC is the directory
# holding sqlite3.c (install.sh unpacks it to /opt/sqlite-amalgamation). Options from sqlite.org's "recommended
# compile-time options"; SQLITE_PRIVATE is left empty so the B-tree functions are visible to lite.c.
require "mkmf"

src = ENV.fetch("SQLITE_SRC", "/opt/sqlite-amalgamation")
abort "no sqlite3.c in #{src}" unless File.exist?(File.join(src, "sqlite3.c"))
$INCFLAGS << " -I#{src}"
$CFLAGS << " -O3 #{ENV.fetch("NATIVE", "")} #{ENV.fetch("PGO", "")}" \
           " -DSQLITE_PRIVATE= -DSQLITE_THREADSAFE=0 -DSQLITE_DQS=0 -DSQLITE_DEFAULT_MEMSTATUS=0" \
           " -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_MAX_EXPR_DEPTH=0" \
           " -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_USE_ALLOCA" \
           " -Wno-unused-function -Wno-unused-parameter -Wno-missing-noreturn"
$LDFLAGS << " #{ENV.fetch("PGO", "")}"
$LIBS << " -lm"
create_makefile("lite")
