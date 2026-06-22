#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Safe Node Takedown demo  —  "Is it safe to take this node down?"
#
# Before you restart, upgrade, or decommission a node, you want one question
# answered: will the cluster stay fully available if this node disappears?
# yb-admin are_nodes_safe_to_take_down answers it — by checking, for every
# tablet and the master quorum, that a caught-up majority survives the takedown.
#
#   Act 0 · Healthy cluster   — the check passes (SAFE)
#   Act 1 · A lagging replica — delete a peer; throttled re-bootstrap → UNSAFE
#   Act 2 · An RF1 tablet     — collapse to a single copy → UNSAFE
#
# Pre-requisites (handled by the devcontainer postStartCommand → setup.sql):
#   - 3-node RF3 yugabyted cluster   n1 127.0.0.1 · n2 127.0.0.2 · n3 127.0.0.3
#     (starts fully healthy; Act 1 throttles remote bootstrap at runtime)
#   - table `big`: one tablet, 100k rows (so a lost replica is slow to rebuild)
#
# The scenarios themselves live in scenario.sh; this script narrates and runs
# them in order. Master addresses are passed via $MASTERS.
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f

TYPE_SPEED=90
NO_WAIT=false
NO_WAIT_DISPLAY_CMD=true
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

export MASTERS="127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100"

clear

# ── Intro ────────────────────────────────────────────────────────────────────
p "=== YugabyteDB: Is it safe to take this node down? ==="
p ""
p "Before any planned node maintenance — restart, upgrade, decommission — you need"
p "to know the cluster will stay available. yb-admin gives you a single pre-flight check:"
p ""
p "  yb-admin -master_addresses \$MASTERS are_nodes_safe_to_take_down <server-uuids> [follower_lag_bound_ms]"
p ""
p "It inspects every tablet (and the master quorum) and confirms a CAUGHT-UP MAJORITY"
p "would survive losing those nodes. Exit 0 = safe; a non-zero exit + message = unsafe."
p ""
p "Our lab: a 3-node RF3 cluster, and one table 'big' with a single tablet — so that"
p "tablet has exactly three Raft peers, one per node. Let's look:"

pe "bash scenario.sh show"

# ── Act 0: healthy ────────────────────────────────────────────────────────────
p ""
p "=== Act 0: a healthy cluster — the check passes ==="
p ""
p "All three peers are caught up. Ask whether we can take down n1:"

pe "bash scenario.sh baseline"

p ""
p "SAFE. Losing any one node still leaves two caught-up peers — a majority of three."

# ── Act 1: lagging replica ─────────────────────────────────────────────────────
p ""
p "=== Act 1: a replica that can't catch up ==="
p ""
p "Now we break it. First we throttle remote bootstrap to 10 bytes/sec on every tserver"
p "(simulating a huge tablet that takes a long time to copy). Then we delete the tablet's"
p "replica on n1 — so the leader must rebuild it from scratch via REMOTE BOOTSTRAP, which"
p "at ten bytes per second effectively never finishes. n1 stays a voter, but a lagging one."
p ""
p "With one replica stuck rebuilding, is it now safe to take down n2 as well?"

pe "bash scenario.sh lag"

p ""
p "UNSAFE — and correctly so. This is the failure that bites real clusters: never take"
p "a second node down while a replica is still catching up from the first event."

# ── Reset ──────────────────────────────────────────────────────────────────────
p ""
p "Let's heal the tablet (drop & recreate it) before the next scenario:"

pe "bash scenario.sh reset"

# ── Act 2: RF1 tablet ──────────────────────────────────────────────────────────
p ""
p "=== Act 2: a tablet with only one copy (RF1) ==="
p ""
p "A different way to lose redundancy: collapse the Raft config to a SINGLE voter."
p "yb-ts-cli unsafe_config_change is the last-resort tool that rewrites a tablet's"
p "config in place — here we force it down to just the leader. The tablet is now RF1."
p ""
p "Is it safe to take down the node that holds that single copy?"

pe "bash scenario.sh rf1"

p ""
p "UNSAFE — taking it down loses the only copy of the data. The check reports the"
p "tablet 'under-replicated by 2 replicas' (one live copy where three are wanted)."

# ── Summary ──────────────────────────────────────────────────────────────────
p ""
p "=== Key Mental Models  (Safe Node Takedown) ==="
p ""
p "THE CHECK     yb-admin are_nodes_safe_to_take_down <uuids> [follower_lag_bound_ms]"
p "              exit 0 + no output = SAFE   |   non-zero exit + 'under-replicated' = UNSAFE"
p "WHAT IT MEANS for every tablet & the master quorum, a CAUGHT-UP MAJORITY survives the takedown"
p ""
p "TWO WAYS TO BE UNSAFE"
p "  1. A lagging follower  — a peer still rebuilding (slow remote bootstrap, big tablet)"
p "                           can't count toward the majority. Don't stack maintenance events."
p "  2. An under-replicated — RF1 / lost copies. The node holds data with no other live copy."
p "     tablet"
p ""
p "DIAGNOSTICS   list_all_tablet_servers · list_tablets <ks> <tbl> · list_tablet_servers <tablet>"
p "              yb-ts-cli ... delete_tablet / unsafe_config_change  (operate on ONE tserver)"
p "KNOB          remote_bootstrap_rate_limit_bytes_per_sec throttles replica rebuild speed"
p ""
p "Rule of thumb: ALWAYS run are_nodes_safe_to_take_down before pulling a node, and pass a"
p "follower_lag_bound_ms that matches your tolerance. If it says unsafe, wait for catch-up."
p ""

cmd

p ""
