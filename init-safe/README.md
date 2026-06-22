# Safe Node Takedown — `are_nodes_safe_to_take_down`

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/pgyogesh/ybdb-vanguard/tree/support?devcontainer_path=.devcontainer%2Finit-safe%2Fdevcontainer.json)

> **Support / Ops exercise.** This is a support-team lab and is **not** part of the upstream `srinivasa-vasu/ybdb-vanguard` exercise set.

Before you restart, upgrade, or decommission a node, you want one question answered: **if this node disappears, does the cluster stay fully available?** YugabyteDB gives you a single pre-flight check for exactly this:

```bash
yb-admin -master_addresses $MASTERS are_nodes_safe_to_take_down <server-uuids> [follower_lag_bound_ms]
```

It walks **every tablet** (and the master quorum) and confirms that a **caught-up majority** would survive losing the listed nodes. This exercise shows it passing on a healthy cluster, then reproduces the **two ways it correctly says "no"** — a replica that can't catch up, and a tablet down to a single copy.

---

## How the check decides

For each tablet, taking down a node is **safe** only if, after the node is gone, the remaining replicas can still form a **majority that is caught up** (within `follower_lag_bound_ms` of the leader). It fails the check when:

| Situation | Why it's unsafe |
|---|---|
| A replica is **lagging** (e.g. still being remote-bootstrapped) | It doesn't count toward the live majority — taking down another node leaves no caught-up majority |
| A tablet is **under-replicated** (RF1, or replicas already lost) | The node may hold the **only** copy; taking it down loses availability (or data) |

The verdict is delivered by the **exit code**:

```
exit 0, no output                       → SAFE
non-zero exit + "...would be under-replicated"  → UNSAFE
```

> `are_nodes_safe_to_take_down` takes one or more **server UUIDs** (comma-separated) — works for tservers and masters. The optional `follower_lag_bound_ms` sets how far behind a follower may be and still count as caught-up.

---

## The cluster is ready when the container starts

The devcontainer's `postStartCommand` starts a **3-node RF3** cluster and runs [`setup.sql`](setup.sql), so you have:

- Nodes **n1 `127.0.0.1`**, **n2 `127.0.0.2`**, **n3 `127.0.0.3`** — masters on `:7100`, tservers on `:9100`.
- Table **`big`**: a single tablet (`SPLIT INTO 1 TABLETS`) with 100k rows — so that one tablet has **exactly three Raft peers**, one per node, and a lost replica is slow to rebuild.

```bash
export MASTERS=127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100
yb-admin -master_addresses $MASTERS list_all_tablet_servers
yb-admin -master_addresses $MASTERS list_tablets ysql.yugabyte big 0
```

---

## Two ways to run this

| Option | How |
|---|---|
| **Guided demo** | **Terminal → Run Task → `safe-demo`**, then `bash prompt.sh`. Auto-types and runs each act in order. |
| **Manual workshop** | **Terminal → Run Task → `admin`** (a shell with `$MASTERS` preset) and run the steps below yourself. |

Both drive the same helper, [`scenario.sh`](scenario.sh):

```bash
bash scenario.sh show       # cluster + the single big tablet and its 3 peers
bash scenario.sh baseline   # safety check on a HEALTHY cluster        → SAFE
bash scenario.sh lag        # delete a replica, throttle rebuild, check → UNSAFE
bash scenario.sh reset      # drop & recreate the big table (heal it)
bash scenario.sh rf1        # collapse the tablet to RF1, then check    → UNSAFE
```

Run the acts **in order** — `baseline` first (it must see a pristine, fully-replicated cluster), `rf1` last (its damage doesn't self-heal). Use `reset` to recover the tablet in between.

---

## Workshop

Throughout, set `MASTERS` once (the `admin` task does this for you):

```bash
export MASTERS=127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100
```

### Act 0 — a healthy cluster passes

Find the tablet and its three peers, then ask whether n1 can be taken down:

```bash
TABLET=$(yb-admin -master_addresses $MASTERS list_tablets ysql.yugabyte big 0 | awk 'NR==2{print $1}')
yb-admin -master_addresses $MASTERS list_tablet_servers $TABLET
#  Server UUID                       RPC Host/Port     Role
#  ...                               127.0.0.1:9100    FOLLOWER
#  ...                               127.0.0.3:9100    FOLLOWER
#  ...                               127.0.0.2:9100    LEADER

N1=$(yb-admin -master_addresses $MASTERS list_all_tablet_servers | awk 'index($0,"127.0.0.1:9100"){print $1}')
yb-admin -master_addresses $MASTERS are_nodes_safe_to_take_down $N1 ; echo "exit=$?"
#  exit=0      ← SAFE: losing any one node still leaves a caught-up majority of three
```

### Act 1 — a replica that can't catch up

Throttle remote bootstrap to a crawl, then delete the replica on n1. The leader must rebuild it from scratch — at 10 bytes/sec it never finishes, so n1 is a **lagging voter**:

```bash
# 1. throttle remote bootstrap on every tserver (runtime gflag)
for ts in 127.0.0.1:9100 127.0.0.2:9100 127.0.0.3:9100; do
  yb-ts-cli --server_address=$ts set_flag remote_bootstrap_rate_limit_bytes_per_sec 10
done

# 2. delete n1's replica — it must now be re-bootstrapped (throttled)
yb-ts-cli --server_address=127.0.0.1:9100 delete_tablet -force $TABLET "lost replica"

# 3. is it safe to take down n2 now?
N2=$(yb-admin -master_addresses $MASTERS list_all_tablet_servers | awk 'index($0,"127.0.0.2:9100"){print $1}')
yb-admin -master_addresses $MASTERS are_nodes_safe_to_take_down $N2 ; echo "exit=$?"
```

```
Error running are_nodes_safe_to_take_down: Illegal state (...): Unable to check if nodes
are safe to take down: 1 tablet(s) would be under-replicated. Example: tablet <big-tablet>
would be under-replicated by 1 replicas (master error 34)
exit=1      ← UNSAFE
```

Taking down n2 would leave only n3 caught up (n1 is still rebuilding) — no caught-up majority. **The real-world lesson: never take a second node down while a replica is still catching up from the first event.** Heal it before moving on:

```bash
bash scenario.sh reset
```

### Act 2 — a tablet with only one copy (RF1)

A different way to lose redundancy: rewrite the Raft config in place down to a single voter with `unsafe_config_change` (a last-resort recovery tool — it operates on one tserver and forces its view of the config):

```bash
TABLET=$(yb-admin -master_addresses $MASTERS list_tablets ysql.yugabyte big 0 | awk 'NR==2{print $1}')
LEADER_UUID=$(yb-admin -master_addresses $MASTERS list_tablet_servers $TABLET | awk '/LEADER/{print $1}')
LEADER_ADDR=$(yb-admin -master_addresses $MASTERS list_tablet_servers $TABLET | awk '/LEADER/{print $2}')

# force the config down to just the leader → tablet is now RF1
yb-ts-cli --server_address=$LEADER_ADDR unsafe_config_change $TABLET $LEADER_UUID
yb-admin -master_addresses $MASTERS list_tablet_servers $TABLET   # one peer only

# is it safe to take down the node holding the only copy?
yb-admin -master_addresses $MASTERS are_nodes_safe_to_take_down $LEADER_UUID ; echo "exit=$?"
```

```
Error running are_nodes_safe_to_take_down: ... N tablet(s) would be under-replicated.
Example: tablet <big-tablet> would be under-replicated by 2 replicas (master error 34)
exit=1      ← UNSAFE
```

The node holds the tablet's **only** copy — taking it down loses the data outright. "Under-replicated by **2**" = one live copy where three are wanted. (The exact tablet *count* in the message depends on the cluster's current state; what matters is the non-zero exit and an under-replicated tablet.)

---

## Diagnostics reference

```bash
# cluster + tablets
yb-admin -master_addresses $MASTERS list_all_tablet_servers
yb-admin -master_addresses $MASTERS list_tablets ysql.yugabyte big 0
yb-admin -master_addresses $MASTERS list_tablet_servers <tablet-id>     # peers + roles
yb-admin -master_addresses $MASTERS list_tablets_for_tablet_server <ts-uuid>

# the safety check (optionally with a follower-lag tolerance in ms)
yb-admin -master_addresses $MASTERS are_nodes_safe_to_take_down <uuid>[,<uuid>...] [follower_lag_bound_ms]

# per-tserver operations (one server at a time)
yb-ts-cli --server_address=<ip>:9100 set_flag remote_bootstrap_rate_limit_bytes_per_sec <bytes>
yb-ts-cli --server_address=<ip>:9100 delete_tablet -force <tablet-id> "<reason>"
yb-ts-cli --server_address=<ip>:9100 unsafe_config_change <tablet-id> <peer-uuid> [<peer-uuid>...]
```

> ⚠️ `delete_tablet` and `unsafe_config_change` are **destructive recovery tools**. They are safe to use freely **in this throwaway lab**, but in production they bypass Raft safety and can cause data loss — reach for them only under guidance.

---

## Key mental models

- **Always run `are_nodes_safe_to_take_down` before pulling a node.** Exit 0 = go; a non-zero exit naming an under-replicated tablet = wait.
- **Two failure modes:** a *lagging follower* (a replica still rebuilding — slow remote bootstrap, large tablet) and an *under-replicated tablet* (RF1 / lost copies). The check catches both.
- **Don't stack maintenance events.** After a node event, a replica may be re-bootstrapping; taking down a second node before it catches up is the classic way to lose a quorum.
- **`remote_bootstrap_rate_limit_bytes_per_sec`** governs how fast a replica rebuilds — on a real cluster a large tablet plus a conservative limit means catch-up takes real time, which is precisely the window this check protects.

## Reference

- [`yb-admin` reference](https://docs.yugabyte.com/stable/admin/yb-admin/)
- [`yb-ts-cli` reference](https://docs.yugabyte.com/stable/admin/yb-ts-cli/)
- [Manage and upgrade — node maintenance](https://docs.yugabyte.com/stable/manage/)
- [Replication & Raft](https://docs.yugabyte.com/stable/architecture/docdb-replication/replication/)
