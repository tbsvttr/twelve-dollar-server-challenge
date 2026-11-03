package borg.trikeshed.components

actual val platformName: String = "wasmWasi"

actual val capabilities: String = "WASI preview1: common components only; the Kotlin/Wasm WASI stdlib has no file API and preview1 has no socket creation or TLS, so file, network and TLS cases are not claimed"

actual fun scratchPath(name: String): String = name

actual fun fileRoundTrip(path: String, bytes: ByteArray, rounds: Int): Long? = null
