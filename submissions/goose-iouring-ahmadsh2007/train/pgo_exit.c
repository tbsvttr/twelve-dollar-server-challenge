/* Linked into the instrumented training build only (never into the shipped server): SIGTERM
 * ends the process through exit(), so the profile counters are written out. */
#include <signal.h>
#include <stdlib.h>
static void on_term(int sig) { (void)sig; exit(0); }
__attribute__((constructor)) static void install(void) { signal(SIGTERM, on_term); }
