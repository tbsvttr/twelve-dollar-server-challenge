/* Build-time helper only. Never linked into the production server.
 * The synthetic HTTP driver drains every response before requesting a dump.
 * sigwait runs libgcov in an ordinary thread, never in a signal handler.
 * Keep this object uninstrumented so generate/use application CFGs match. */
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

extern void __gcov_dump(void);

static sigset_t finish_signal;

static void *finish_training(void *unused) {
    (void)unused;
    int received = 0;
    if (sigwait(&finish_signal, &received) != 0 || received != SIGUSR1) {
        fputs("PGO: could not receive training completion signal\n", stderr);
        _Exit(1);
    }
    __gcov_dump();
    /* The database is disposable; committed responses were drained already.
     * _Exit avoids a second libgcov flush and never runs application teardown
     * concurrently with its idle event loop. */
    _Exit(0);
}

__attribute__((constructor)) static void prepare_training_exit(void) {
    sigemptyset(&finish_signal);
    sigaddset(&finish_signal, SIGUSR1);
    if (pthread_sigmask(SIG_BLOCK, &finish_signal, NULL) != 0) {
        fputs("PGO: could not block training completion signal\n", stderr);
        _Exit(1);
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, finish_training, NULL) != 0) {
        fputs("PGO: could not start profile dump thread\n", stderr);
        _Exit(1);
    }
    pthread_detach(thread);
}
