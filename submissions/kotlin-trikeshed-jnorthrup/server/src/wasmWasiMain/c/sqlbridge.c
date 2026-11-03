/*
 * The WASI build's byte bridge, linked into the SQLite module beside the stock amalgamation (sqlite3.c is not
 * changed). wasmtime gives every instance its own linear memory and Kotlin/Wasm cannot address another instance's, so
 * the Kotlin module moves SQL text, bound values and column bytes through these exports: allocation, then eight bytes
 * per call where the run allows, one byte for the tail.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wasi/libc.h>

/*
 * wasi-libc's own preopen scan stops at the first descriptor without a prestat, and wasmtime -S tcplisten puts the
 * listening socket there (fd 3), so libc sees no directory and every open fails. The Kotlin side scans past it and
 * registers each directory here; libc's scan runs first so it cannot run again later and reset the table.
 */
__attribute__((export_name("ts_preopen"))) int32_t ts_preopen(int32_t fd, const char *prefix) {
    __wasilibc_populate_preopens();
    return __wasilibc_register_preopened_fd(fd, prefix);
}

__attribute__((export_name("ts_alloc"))) void *ts_alloc(int32_t n) { return malloc(n > 0 ? (size_t)n : 1); }
__attribute__((export_name("ts_free"))) void ts_free(void *p) { free(p); }
__attribute__((export_name("ts_load64"))) int64_t ts_load64(const uint8_t *p) { int64_t v; memcpy(&v, p, 8); return v; }
__attribute__((export_name("ts_store64"))) void ts_store64(uint8_t *p, int64_t v) { memcpy(p, &v, 8); }
__attribute__((export_name("ts_load8"))) int32_t ts_load8(const uint8_t *p) { return *p; }
__attribute__((export_name("ts_store8"))) void ts_store8(uint8_t *p, int32_t v) { *p = (uint8_t)v; }
