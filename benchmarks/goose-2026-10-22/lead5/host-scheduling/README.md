The snapshots show competing host work and do not establish that a background
policy forced the benchmark's guest CPU 0 onto efficiency cores. No process,
priority, power setting, VM setting or benchmark source was changed.

The host reports 12 physical/logical CPUs, with performance-level counts 8 and
4. AC low-power mode was 0. Docker's running VM is Apple's Virtualization XPC
process, PID 15432. Its visible thread priorities were all `31T`, nice 0. These
priority values alone do not identify each thread's QoS or its physical core.

Four Python workers, PIDs 25186, 25187, 25218 and 25219, started at local
13:50:42–43 on October 22. Each reached roughly 85–94% CPU in one snapshot;
Chrome and WindowServer were also busy. The workers had exited naturally by
13:52:45. This is concrete competing load. It can affect scheduling, frequency,
cache and memory bandwidth, but these snapshots do not quantify its effect on
any particular throughput attempt.

`read_usage.py` makes one read-only `proc_pid_rusage(V6)` call per PID using the
installed SDK's structure layout. The two retained VM snapshots show mostly
legacy QoS accounting, with no background-QoS increment in their interval.
P-core-only time was 9.80% of aggregate VM CPU time in that 42.96-second interval.
This covers every VM thread, overlaps screen completion/idle time, and cannot
map guest CPU 0 to a host core or establish the cause of an earlier RPS change.
The raw counter values and arithmetic are retained in `usage-interval.json`.

Apple describes virtual CPUs as host POSIX threads in its [Hypervisor
documentation](https://developer.apple.com/documentation/hypervisor). Thus Linux
`--cpuset-cpus 0` constrains a guest virtual CPU; it does not reserve a specific
Mac physical core. Apple's [CPU scheduling
talk](https://developer.apple.com/videos/play/tech-talks/110147/) explains that
CPU priority and QoS influence core selection and resource access. The kernel's
[Recount documentation](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md)
describes cumulative per-core-kind accounting and the P-core-only counters.

Docker's [Resource Saver
documentation](https://docs.docker.com/desktop/use-desktop/resource-saver/)
says it stops an idle VM when no containers are running. That documented mode
does not explain active throughput while benchmark containers are running.
Local `taskpolicy(8)` says `-B` removes Darwin background status; it does not
promise P-core affinity, and no such status was established here.

For the requested busy-Mac continuation, keep both implementations' limits
identical, use the separately labeled concurrent shared-CPU A/A-gated diagnostic
for selection, then retain the predeclared longer dedicated-guest-CPU holdout
with unchanged controls and every attempt. Concurrent ratios can reduce common
host variation, but shared-CPU contention changes the experiment and cannot
replace the one-CPU throughput criterion. A quiet host or dedicated native Linux
host would be a separate way to reduce external variability. No scheduling
change is justified by these readings alone.
