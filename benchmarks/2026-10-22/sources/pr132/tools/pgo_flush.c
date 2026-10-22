/* LD_PRELOAD shim used ONLY while training the PGO build.
 *
 * The default single-process server installs no signal handler: SIGTERM has
 * the normal "terminate now" action, which does NOT run atexit handlers. GCC's
 * `-fprofile-generate` runtime flushes its counters from an exit handler, so a
 * plain `kill -TERM` loses the profile and the second PGO pass gets nothing.
 *
 * This shim's constructor installs a SIGTERM/SIGINT handler that calls
 * `exit(0)`, which runs the gcov exit handler and writes the .gcda files. The
 * server is single-threaded, so calling exit() from the handler is safe here.
 *
 * It is compiled to `tools/libpgoflush.so` (gitignored) by build.sh and is
 * loaded with LD_PRELOAD for the training run only. It is never linked into the
 * shipped server, and it does not alter any response bytes.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <stdlib.h>

static void pgo_on_signal(int sig) {
  (void)sig;
  exit(0); /* runs gcov's exit handler -> profile data is flushed */
}

__attribute__((constructor)) static void pgo_install_handlers(void) {
  signal(SIGTERM, pgo_on_signal);
  signal(SIGINT, pgo_on_signal);
}
