
#define _POSIX_C_SOURCE 200112L
#define _DEFAULT_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include "stats.h"
static uint64_t wall_us,monotonic_us;
static int mock_gettimeofday(struct timeval *t,void *zone) {
    (void)zone;t->tv_sec=wall_us/1000000;t->tv_usec=wall_us%1000000;return 0;
}
static int mock_clock_gettime(clockid_t clock,struct timespec *t) {
    assert(clock==CLOCK_MONOTONIC);
    t->tv_sec=monotonic_us/1000000;t->tv_nsec=(monotonic_us%1000000)*1000;return 0;
}
static uint64_t stock_time_us() {
    struct timeval t;
    mock_gettimeofday(&t, NULL);
    return (t.tv_sec * 1000000) + t.tv_usec;
}
static uint64_t monotonic_time_us() {
    struct timespec t;
    mock_clock_gettime(CLOCK_MONOTONIC, &t);
    return ((uint64_t)t.tv_sec * 1000000) + (t.tv_nsec / 1000);
}
static void record(stats *histogram, errors *counts, uint64_t delta) { if (!stats_record(histogram, delta)) {
            counts->timeout++;
        } }
int main(void) {
    stats *old_hist=stats_alloc(2000000),*new_hist=stats_alloc(2000000);
    errors old_errors={0},new_errors={0};
    wall_us=monotonic_us=1000000;
    uint64_t old_start=stock_time_us(),new_start=monotonic_time_us();
    wall_us=990000;monotonic_us=1000500;
    uint64_t old_delta=stock_time_us()-old_start,new_delta=monotonic_time_us()-new_start;
    record(old_hist,&old_errors,old_delta);record(new_hist,&new_errors,new_delta);
    assert(old_delta==UINT64_MAX-9999 && new_delta==500);
    assert(old_errors.timeout==1 && new_errors.timeout==0);
    assert(old_hist->count==0 && new_hist->count==1 && new_hist->max==500);
    wall_us=monotonic_us=4000001;
    record(old_hist,&old_errors,stock_time_us()-old_start);
    record(new_hist,&new_errors,monotonic_time_us()-new_start);
    assert(old_errors.timeout==2 && new_errors.timeout==1);
    assert(old_hist->count==0 && new_hist->count==1);
    printf("{\"passed\":true,\"stock_backwards_delta_us\":%llu,\"monotonic_delta_us\":%llu,"
           "\"backward_step_stock_timeouts\":1,\"backward_step_monotonic_timeouts\":0,"
           "\"real_over_two_second_duration_counted_by_both\":true,"
           "\"timeout_logic_unchanged\":true}\n",(unsigned long long)old_delta,(unsigned long long)new_delta);
    stats_free(old_hist);stats_free(new_hist);return 0;
}
