#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scenario.sh — the are_nodes_safe_to_take_down scenarios, runnable standalone
#
#   bash scenario.sh show       cluster + the single big tablet and its 3 peers
#   bash scenario.sh reset      drop & recreate the big table (fresh healthy tablet)
#   bash scenario.sh baseline   safety check on a HEALTHY cluster        → SAFE
#   bash scenario.sh lag        delete a replica, then re-check          → UNSAFE
#   bash scenario.sh rf1        collapse the tablet to RF1, then check   → UNSAFE
#
# The cluster is the fixed 3-node yugabyted cluster this devcontainer starts:
#   n1 127.0.0.1   n2 127.0.0.2   n3 127.0.0.3   (RF3, masters on :7100)
# It starts HEALTHY (fully replicated). The `lag` scenario throttles
# remote_bootstrap_rate_limit_bytes_per_sec to 10 at runtime so a replica that
# has to be re-bootstrapped never catches up — exactly the "lagging follower"
# are_nodes_safe_to_take_down is meant to catch.
# ─────────────────────────────────────────────────────────────────────────────

MASTERS="${MASTERS:-127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100}"
KEYSPACE="ysql.yugabyte"
TABLE="big"
TSERVERS=(127.0.0.1:9100 127.0.0.2:9100 127.0.0.3:9100)
ADMIN=(yb-admin -master_addresses "$MASTERS")

# ── throttle remote bootstrap on every tserver (runtime gflag) ────────────────
throttle_rbs() {
  local bytes="$1"
  for ts in "${TSERVERS[@]}"; do
    yb-ts-cli --server_address="$ts" set_flag remote_bootstrap_rate_limit_bytes_per_sec "$bytes" >/dev/null
  done
}

# ── discovery helpers (tab-aware: list_tablets' Range column contains spaces) ─
tablet_id()   { "${ADMIN[@]}" list_tablets "$KEYSPACE" "$TABLE" 0 | awk 'NR==2{print $1}'; }
uuid_at()     { "${ADMIN[@]}" list_all_tablet_servers | awk -v ip="$1" 'index($0,ip){print $1}'; }
leader_uuid() { "${ADMIN[@]}" list_tablet_servers "$1" | awk '/LEADER/{print $1}'; }
leader_addr() { "${ADMIN[@]}" list_tablet_servers "$1" | awk '/LEADER/{print $2}'; }

# ── run are_nodes_safe_to_take_down and report the verdict clearly ────────────
safe_check() {
  local uuid="$1" label="$2" out rc
  echo "→ yb-admin -master_addresses \$MASTERS are_nodes_safe_to_take_down ${label} (${uuid})"
  out="$("${ADMIN[@]}" are_nodes_safe_to_take_down "$uuid" 2>&1)"; rc=$?
  [ -n "$out" ] && echo "$out"
  if [ "$rc" -eq 0 ]; then
    echo "✅ SAFE  (exit 0) — these nodes can be taken down together."
  else
    echo "⛔ UNSAFE (exit ${rc}) — do NOT take this node down right now."
  fi
  return 0
}

recreate_table() {
  ysqlsh -h 127.0.0.1 -X -q -c "DROP TABLE IF EXISTS ${TABLE};" \
    -c "CREATE TABLE ${TABLE} (id int PRIMARY KEY, v text) SPLIT INTO 1 TABLETS;" \
    -c "INSERT INTO ${TABLE} SELECT g, repeat('x',1000) FROM generate_series(1,100000) g;"
  "${ADMIN[@]}" flush_table "$KEYSPACE" "$TABLE" 60 >/dev/null 2>&1 || true
}

case "${1:-show}" in

  show)
    echo "── Tablet servers ──────────────────────────────────────────────"
    "${ADMIN[@]}" list_all_tablet_servers
    echo ""
    echo "── The '${TABLE}' table: one tablet, three Raft peers ──────────"
    "${ADMIN[@]}" list_tablets "$KEYSPACE" "$TABLE" 0
    local_t="$(tablet_id)"
    "${ADMIN[@]}" list_tablet_servers "$local_t"
    echo ""
    ysqlsh -h 127.0.0.1 -X -c "SELECT count(*) AS rows FROM ${TABLE};"
    ;;

  reset)
    echo "Recreating a fresh, fully-replicated '${TABLE}' tablet..."
    recreate_table
    echo "Done. Peers:"
    "${ADMIN[@]}" list_tablet_servers "$(tablet_id)"
    ;;

  baseline)
    T="$(tablet_id)"
    echo "Healthy RF3 tablet ${T} — all three peers caught up:"
    "${ADMIN[@]}" list_tablet_servers "$T"
    echo ""
    safe_check "$(uuid_at 127.0.0.1:9100)" "n1"
    echo ""
    echo "Any single node can go: the other two still form a caught-up majority."
    ;;

  lag)
    T="$(tablet_id)"
    echo "Tablet ${T} before: three healthy peers."
    "${ADMIN[@]}" list_tablet_servers "$T"
    echo ""
    echo "→ Throttle remote bootstrap to 10 bytes/sec on every tserver, so any replica"
    echo "  that has to be rebuilt cannot catch up (simulates a huge, slow-to-copy tablet):"
    echo "  yb-ts-cli --server_address=<ts> set_flag remote_bootstrap_rate_limit_bytes_per_sec 10"
    throttle_rbs 10
    echo ""
    echo "→ Deleting the replica on n1 (127.0.0.1). The leader must now rebuild it from"
    echo "  scratch via remote bootstrap — at 10 bytes/sec, so it never catches up:"
    yb-ts-cli --server_address=127.0.0.1:9100 delete_tablet -force "$T" "init-safe: simulate a lost replica"
    echo ""
    echo "n1 is still a voter in the Raft config, but its data is gone and it is"
    echo "stuck re-bootstrapping. Now ask: is it safe to take down n2 as well?"
    echo ""
    safe_check "$(uuid_at 127.0.0.2:9100)" "n2"
    echo ""
    echo "Taking down n2 would leave only n3 caught up (n1 is still rebuilding) —"
    echo "no caught-up majority → the tablet would be under-replicated. Correctly refused."
    ;;

  rf1)
    T="$(tablet_id)"
    L_UUID="$(leader_uuid "$T")"
    L_ADDR="$(leader_addr "$T")"
    echo "Tablet ${T} — leader is ${L_UUID} on ${L_ADDR}."
    echo ""
    echo "→ Forcing the Raft config down to a SINGLE voter (the leader) with the"
    echo "  last-resort surgery yb-ts-cli unsafe_config_change:"
    yb-ts-cli --server_address="$L_ADDR" unsafe_config_change "$T" "$L_UUID"
    sleep 6
    echo ""
    echo "The tablet is now RF1 — a single copy, no redundancy:"
    "${ADMIN[@]}" list_tablet_servers "$T"
    echo ""
    safe_check "$L_UUID" "the RF1 node"
    echo ""
    echo "This node holds the tablet's ONLY copy — taking it down loses the data"
    echo "outright. The check refuses it ('under-replicated by 2 replicas')."
    ;;

  *)
    echo "usage: bash scenario.sh {show|reset|baseline|lag|rf1}" >&2
    exit 2
    ;;
esac
