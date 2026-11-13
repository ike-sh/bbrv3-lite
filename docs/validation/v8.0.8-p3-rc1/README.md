# P3-RC1 budget semantics evidence

This directory records new-build local/container regression, not a new live
VPS measurement. The old P3 build and its actual 1142.86 Mbit/s measurement,
early RC70, mutation rollback and production-integrity evidence remain in the
P3 report. The qualification status remains `P3_NOT_QUALIFIED`.

`production-replay-*` use the anonymized deterministic fixture in
`tests/fixtures/v808-p3-budget-semantics`. Network I/O, interface counters,
elapsed time and qdisc mutation are test doubles; production budgeting,
remaining-work model, failure propagation and history writers/readers run.
The incident counter is 2562106393 / 6442450944 bytes, with 3880344551 bytes
still available. The expected plan is 14640332764 bytes; its conservative
upper bound is a different field. No real public iperf endpoint is contacted
by this fixture.

The matrix uses the project's unchanged `scripts/docker-validate.sh`. On this
Windows/WSL workstation an external Docker CLI adapter converts the `/mnt/d`
source bind path for native `docker.exe`; product and validation scripts are
unchanged. Container integration uses real loopback/network namespaces and
disposable runtime state. These results do not qualify a new VPS build.

`proposed-real-vps-readonly-check.sh` is a reviewable, unexecuted follow-up.
Its new-build SHA is pinned; it reads/copies the old P3 evidence into a new
`/tmp` directory, checks new CLI output, runs the deterministic test in a
network namespace, and compares production files/network/service before and
after. It does not run real iperf or change production networking. It requires
the matching uploaded payload and a verified, existing old P3 evidence source;
missing evidence is NOT RUN, not PASS. No SSH connection or upload was made
for this proposal during the repair campaign.
