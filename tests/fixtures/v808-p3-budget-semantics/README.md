# P3 budget-failure semantics fixture

Numeric inputs come from the real P3 run documented in
`docs/v8.0.8-p3-real-vps-qualification-report.md`: capacity 1142.86 Mbit/s,
five valid samples, standard/manual sweep, 6 GiB / 900s, and an early RC70.
The original build was SHA256
`4e9761e1c45b9a4d1267413ee8b37a555ab6ee3352ff6d9d45b31c69d3d2c5bf`.

`legacy-summary.tsv` is a selected, anonymized key/value record; addresses,
host identity and path fingerprints are excluded. `legacy-failure.tsv`
preserves the erroneous reason text. Sample timestamps are replaced with a
fixed test epoch. These files are not byte-for-byte production history.

The deterministic sweep replaces network I/O and qdisc mutation, retains the
real budget guard/model/finalization, and feeds these five sample tuples.
Sender bytes are charged per sample; the remaining counter overhead is added
at the final control sample to reproduce the observed gate snapshot exactly.
That distribution is synthetic, not a reconstruction of packet timing.
The elapsed clock is fixed to the recorded 49s. No real iperf is run.

The manual expected remainder is 14640332764 bytes, above the still-positive
3880344551-byte remainder. The conservative branch upper bound is separate;
it is not the gate's required reservation and is not a claimed actual cost.
The test must retain RC70 / budget-exceeded, low decision confidence, no
recommendation or confirmed knee, complete simulated rollback and no config
commit. Existing legacy files remain unchanged when read by the new build.
