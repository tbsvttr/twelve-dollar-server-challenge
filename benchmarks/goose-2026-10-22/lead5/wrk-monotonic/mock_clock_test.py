"""Compile a deterministic unit proof using the actual source clock helpers.

No server or HTTP workload runs. Both variants call the same unmodified
Ubuntu-package stats_record implementation and original timeout condition.
"""
from pathlib import Path
import hashlib,json,re,subprocess,sys

stock,mono,out=map(Path,sys.argv[1:])
a,b=(p.joinpath('src/wrk.c').read_text() for p in (stock,mono))
pattern=r'static uint64_t time_us\(\) \{\n.*?\n\}'
old,new=(re.search(pattern,s,re.S).group() for s in (a,b))
counter='''if (!stats_record(statistics.latency, now - c->start)) {
            thread->errors.timeout++;
        }'''
assert a.count(counter)==b.count(counter)==1
assert (stock/'src/stats.c').read_bytes()==(mono/'src/stats.c').read_bytes()
assert (stock/'src/wrk.h').read_bytes()==(mono/'src/wrk.h').read_bytes()
assert old.count('gettimeofday')==1 and new.count('clock_gettime(CLOCK_MONOTONIC')==1
old=old.replace('time_us()', 'stock_time_us()').replace('gettimeofday(', 'mock_gettimeofday(')
new=new.replace('time_us()', 'monotonic_time_us()').replace('clock_gettime(', 'mock_clock_gettime(')
record=counter.replace('statistics.latency','histogram').replace('now - c->start','delta').replace('thread->errors.timeout','counts->timeout')
program=r'''
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
@OLD@
@NEW@
static void record(stats *histogram, errors *counts, uint64_t delta) { @RECORD@ }
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
'''.replace('@OLD@',old).replace('@NEW@',new).replace('@RECORD@',record)
source=out/'mock-clock.c';source.write_text(program)
argv=['cc','-O2','-std=c99','-D_POSIX_C_SOURCE=200112L','-D_DEFAULT_SOURCE',
      '-I'+str(stock/'src'),str(source),str(stock/'src/stats.c'),str(stock/'src/zmalloc.c'),
      '-pthread','-lm','-o',str(out/'mock-clock')]
compiled=subprocess.run(argv,text=True,capture_output=True)
(out/'mock-clock-build.log').write_text(compiled.stdout+compiled.stderr)
compiled.check_returncode()
ran=subprocess.run([str(out/'mock-clock')],text=True,capture_output=True)
(out/'mock-clock.log').write_text(ran.stdout+ran.stderr)
ran.check_returncode()
result=json.loads(ran.stdout)
result.update(clock_functions_extracted_from_actual_sources=True,
              actual_stats_c_sha256=hashlib.sha256((stock/'src/stats.c').read_bytes()).hexdigest(),
              timeout_condition_sha256=hashlib.sha256(counter.encode()).hexdigest(),
              compile_command=argv,process_exit_code=ran.returncode)
(out/'mock-clock-results.json').write_text(json.dumps(result,indent=2)+'\n')
print(ran.stdout.strip())
