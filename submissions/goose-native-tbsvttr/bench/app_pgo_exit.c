/* Build-time helper only. Never linked into the production server.
 * Keep this object uninstrumented so generate/use application CFGs match.
 * The driver forces epoll and drains responses before sending SIGUSR1.
 * Dump on the application thread at a poll boundary, outside signal context. */
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/epoll.h>

extern void __gcov_dump(void);

static volatile sig_atomic_t finished;

static void request_finish(int number) {
    (void)number;
    finished = 1;
}

static void finish_if_requested(void) {
    if (finished) {
        __gcov_dump();
        /* Responses committed and drained; only a disposable database remains.
         * Avoid a duplicate libgcov exit flush. No application thread races. */
        _Exit(0);
    }
}

__attribute__((constructor)) static void prepare_training_exit(void) {
    struct sigaction action = {0};
    action.sa_handler = request_finish;
    sigemptyset(&action.sa_mask);
    sigset_t blocked;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGUSR1);
    if (sigaction(SIGUSR1, &action, NULL) != 0 ||
        pthread_sigmask(SIG_BLOCK, &blocked, NULL) != 0) {
        fputs("PGO: could not configure training completion signal\n", stderr);
        _Exit(1);
    }
}

/* Interpose only in the instrumented binary. SIGUSR1 stays blocked outside
 * this wait; epoll_pwait atomically unmasks it, preventing a check/wait race.
 * The production binary links libc epoll_wait directly, with no extra branch. */
int epoll_wait(int fd, struct epoll_event *events, int maximum, int timeout) {
    finish_if_requested();
    sigset_t wait_mask;
    if (pthread_sigmask(SIG_SETMASK, NULL, &wait_mask) != 0) {
        fputs("PGO: could not inspect training signal mask\n", stderr);
        _Exit(1);
    }
    sigdelset(&wait_mask, SIGUSR1);
    int result = epoll_pwait(fd, events, maximum, timeout, &wait_mask);
    int saved_errno = errno;
    finish_if_requested();
    errno = saved_errno;
    return result;
}
