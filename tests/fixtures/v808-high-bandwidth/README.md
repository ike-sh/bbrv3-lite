# v8.0.8 production evidence

The supplied incident has 11 successful samples, four busy attempts, and a
pre-spawn budget rejection at RATE_1222_RECHECK_3. `context.tsv` preserves the
exact reported budget counters. `samples.tsv` preserves the supplied sender,
receiver and retransmission percentages; unknown sender values (1098/1160/1222
and recheck 2), earlier PATH_CONTROL loss, timestamps, byte counts, retransmit
counts, duration and local telemetry are deterministic synthetic inputs. They
are not a copy of the unavailable original production file.

Tests insert explicitly synthetic same-rate recovery samples at 1036 (980/982
Mbit/s) to exercise the new bounded qualification. A late-interruption replay
uses the production budget snapshot and disables only the early feasibility
advisory in the test harness, so the original hard pre-spawn guard is exercised.
The normal v8.0.8 entry test instead stops immediately after capacity/control
telemetry because the expected remaining cost exceeds the remaining 6 GiB.
No test contacts the public endpoint or changes host networking.
