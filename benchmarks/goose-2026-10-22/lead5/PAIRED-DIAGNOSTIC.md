# Shared-CPU diagnostic: selection evidence only

The user chose to continue on the busy Mac. The sequential discovery attempts
are all retained, including throughput drops in unchanged controls. A new
diagnostic runs two servers simultaneously on the same guest CPU 0 with equal
default CPU weights and separate fresh databases. Both receive the same mixed
workload from the pinned corrected load image on guest CPUs 1 and 2.

This makes short-term host CPU speed changes common to both servers. It also
changes each server's available CPU share and scheduling conditions. Its raw
throughput is therefore not a one-CPU-per-server result and cannot fulfill the
5% target or replace the predeclared sequential confirmation.

First run identical retained Goose binaries against each other. Two 30-second
samples should produce throughput ratios within 5% and show approximately
equal CPU allocation, with zero errors and valid databases. If this check fails,
do not interpret candidate differences as a reliable optimization signal.

Then use two 30-second samples per candidate/control pair to guide selection,
reversing the instance order. Preserve every attempt, workload, image/source
identity, resource limit, raw output, CPU/RSS sample, error and integrity check.
No builds or other diagnostic workloads run during these measurements. The
ordinary ten-round, 45-second sequential holdout remains the acceptance test.
