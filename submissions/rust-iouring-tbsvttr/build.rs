use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=csrc/engine.c");
    println!("cargo:rerun-if-changed=vendor/sqlite3.c");
    println!("cargo:rerun-if-changed=vendor/sqlite3.h");

    assert!(
        Path::new("vendor/sqlite3.c").exists() && Path::new("vendor/sqlite3.h").exists(),
        "vendor/sqlite3.c missing — run build.sh first"
    );

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));
    let obj_path = out_dir.join("engine.o");
    let lib_path = out_dir.join("libtvcc_sqlite_engine.a");

    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let mut cmd = Command::new(&cc);
    cmd.arg("-c")
        .arg("csrc/engine.c")
        .arg("-Ivendor")
        .arg("-O3")
        .arg("-fPIC")
        .arg("-fomit-frame-pointer")
        .arg("-w")
        .arg("-DSQLITE_THREADSAFE=2")
        .arg("-DSQLITE_DEFAULT_MEMSTATUS=0")
        .arg("-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1")
        .arg("-DSQLITE_LIKE_DOESNT_MATCH_BLOBS")
        .arg("-DSQLITE_MAX_EXPR_DEPTH=0")
        .arg("-DSQLITE_USE_ALLOCA")
        .arg("-DSQLITE_OMIT_DECLTYPE")
        .arg("-DSQLITE_OMIT_DEPRECATED")
        .arg("-DSQLITE_OMIT_PROGRESS_CALLBACK")
        .arg("-DSQLITE_OMIT_SHARED_CACHE")
        .arg("-DSQLITE_OMIT_AUTOINIT")
        .arg("-DSQLITE_OMIT_LOAD_EXTENSION")
        .arg("-DSQLITE_OMIT_UTF16")
        .arg("-DSQLITE_OMIT_TRACE")
        .arg("-DSQLITE_OMIT_COMPLETE")
        .arg("-DSQLITE_OMIT_GET_TABLE")
        .arg("-DSQLITE_OMIT_TCL_VARIABLE")
        .arg("-DSQLITE_DQS=0")
        .arg("-DHAVE_FDATASYNC=1")
        .arg("-DHAVE_USLEEP=1");

    if env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64") {
        cmd.arg("-march=native");
    }

    cmd.arg("-o").arg(&obj_path);
    let status = cmd.status().expect("failed to invoke C compiler");
    assert!(status.success(), "C compilation of csrc/engine.c failed");

    let _ = std::fs::remove_file(&lib_path);
    let ar_status = Command::new("ar")
        .arg("crs")
        .arg(&lib_path)
        .arg(&obj_path)
        .status()
        .expect("failed to invoke ar");
    assert!(ar_status.success(), "ar failed to create static library");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=tvcc_sqlite_engine");
    println!("cargo:rustc-link-lib=pthread");
    #[cfg(target_os = "linux")]
    {
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=dl");
    }
}
