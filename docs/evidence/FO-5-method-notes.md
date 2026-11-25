EXPECTED RED LINES: Diagnostic notes from the drill.
---- raw output below, unchanged ----
# FO-5: how the replication cut was built (observations from 2026-11-19)

Goal: commit rows on the primary that never reach any replica, then lose the primary.

1. First attempt, `iptables -I FORWARD 1 ... -j DROP` on the primary's node: the cut held for about
   4 s, then the rows reached both replicas. The rule counters showed our rules had caught only the
   first packets, while `cali-FORWARD` had moved to line 1 of the chain. Reading: Calico's agent
   re-inserted its jump ahead of our rules. This is an interpretation of the counters, not a proven
   cause. The test stopped on its own safety check (`the cut did not work`). Run saved as
   FO-5-run1-FAILED.txt.
2. Second attempt, a separate nftables table (`ip pgha_fence`, chain hook `forward`, priority -150,
   which `nft` prints as `mangle`): both replicas stayed at 0 divergent rows for 30 s while the
   primary had 5; `replay` on the replicas stayed frozen. Each rule matched 9 packets. The table was
   removed afterwards.
3. A first nft attempt failed on a syntax error because `fwd` is a reserved word in nftables; the
   chain is named `isolate`.

The test refuses to continue if the replicas already hold the rows, so a rejoin can never "pass"
without a real divergence.
