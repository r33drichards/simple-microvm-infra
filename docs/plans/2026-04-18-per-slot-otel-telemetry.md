# Per-Slot OTel Telemetry Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship host-level metrics and systemd-journal logs out of every MicroVM slot into the hypervisor's existing Prometheus + Loki stack via OpenTelemetry, so we have visibility into per-slot resource usage (and can catch the kind of guest memory leak that took down slot1 after 25 days).

**Architecture:** Each slot runs `services.opentelemetry-collector` (package: `opentelemetry-collector-contrib`) with `hostmetrics` + `journald` receivers and an OTLP/gRPC exporter pointing at the bridge gateway IP (`10.X.0.1:4317`). The hypervisor runs a **second** otelcol that receives OTLP on all bridge IPs and fans out: metrics → `prometheusremotewrite` into the existing Prometheus (port 9090), logs → `loki` exporter into existing Loki (port 3100).

The slot-side collector is **NOT** defined in `simple-microvm-infra`. Slot1 and slot2 run in-VM Comin pointing at external repos (`oclaw-nix`, `oclaw-nix-public`); those in-VM `nixos-rebuild switch` runs replace the boot closure within ~15s of boot. Any otelcol config defined only in the simple-microvm-infra-built runner would be wiped. So the per-slot collector module lives in each per-slot repo:

- `github.com/r33drichards/oclaw-nix` → `modules/slot-telemetry.nix` (slot1, endpoint `10.1.0.1:4317`)
- `github.com/r33drichards/oclaw-nix-public` → `modules/slot-telemetry.nix` (slot2, endpoint `10.2.0.1:4317`)
- Slots 3–5 have no in-VM Comin and no per-slot repo; they run the simple-microvm-infra closure directly. **They are not covered by this plan.** If we want slots 3–5 covered, we can wire `slot-telemetry.nix` into `lib/create-vm.nix` as a follow-up (no in-VM override concern for them).

**Tech Stack:** NixOS 25.05, `opentelemetry-collector-contrib`, existing Prometheus/Loki on hypervisor, `services.opentelemetry-collector` NixOS module.

**Why push (OTLP) instead of scraping node_exporter?** Single agent per slot handles metrics + logs uniformly; no inbound port on slot; matches the "OTel through firewall" intent; future-extensible (traces). Cost: ~60–80 MB RAM per slot.

**Pre-approval decisions (baked in):**
- Memory: bump slot1 `microvm.mem` 8192 → 12288 to absorb otelcol + restore headroom after the 25-day leak. Slots 2–5 stay at current values.
- Fix stale slot names in `modules/microvm-auto-restart.nix` (referenced `vm1..vm5`, should be `slot1..slot5`) and flip `services.microvm-auto-restart.enable = true` so the slot1 mem bump (a host-side QEMU arg) actually takes effect on deploy. In-VM Comin can't restart the slot process; this has to happen host-side.
- Cardinality: one resource label only — `slot.id = "slot<N>"` (dropped redundant `host.name` which resolves to the same value).
- Firewall: slot-facing port 4317 is governed by the hypervisor's hand-rolled nftables ruleset in `hosts/hypervisor/network.nix` (the NixOS firewall module is disabled on this host). Bridges + tailscale0 + loopback reach it; the internet is dropped. Matches the existing posture for Grafana/Prometheus/Loki.

---

## Cross-repo push order (important)

`simple-microvm-infra`'s `flake.lock` will need bumped to reference the new `oclaw-nix` and `oclaw-nix-public` revisions that contain the telemetry module — otherwise slot1/slot2 runners built by the hypervisor won't have it at boot (it'll still be added shortly after by in-VM Comin, but there's a ~15s gap at every slot restart where the collector isn't running). Order:

1. Merge + push `oclaw-nix` branch `slot-telemetry` to `main`. In-VM Comin on slot1 picks up the module within 15s (but can't restart the slot process, so the declared collector won't actually appear until the slot is rebooted OR until the hypervisor rebuilds slot1's runner with the updated flake.lock and microvm-auto-restart triggers a restart).
2. Same for `oclaw-nix-public` → slot2.
3. In `simple-microvm-infra`:
   - `nix flake lock --update-input oclaw-nix --update-input oclaw-nix-public`
   - Commit the flake.lock bump on `per-slot-telemetry` branch.
   - Merge to `main`, push.
4. Comin on hypervisor picks up the branch merge within 60s; hypervisor rebuild installs the new receiver on port 4317; microvm-auto-restart restarts slot1 (its mem changed 8192→12288) and slot2 only if its runner changed (it likely does, because flake.lock bump means oclaw-nix-public changed).

---

### Task 1: Add slot-telemetry module to oclaw-nix (slot1)

**Status:** complete on `oclaw-nix` branch `slot-telemetry`.

**Files:**
- Create: `oclaw-nix/modules/slot-telemetry.nix`
- Modify: `oclaw-nix/flake.nix` — add `./modules/slot-telemetry.nix` to `nixosModules.default` imports.

Module content: `hostmetrics` (cpu/load/memory/disk/filesystem/network/paging, 30s interval) + `journald` (from `/var/log/journal`, priority floor `info`), `resource.attributes = [{ slot.id }]`, pipelines `memory_limiter → resource → batch → otlp`, exporter endpoint `10.1.0.1:4317` (TLS off, bridge-local). Also sets `services.journald.storage = "persistent"` so the receiver always has a source.

Verification:
```bash
cd oclaw-nix
git add modules/slot-telemetry.nix flake.nix
nix flake check --no-build 2>&1 | tail -10
nix eval --json .#nixosConfigurations.slot1.config.services.opentelemetry-collector.enable
# → true
```

### Task 2: Add slot-telemetry module to oclaw-nix-public (slot2)

**Status:** complete on `oclaw-nix-public` branch `slot-telemetry`.

Identical module to Task 1 except endpoint is `10.2.0.1:4317`.

### Task 3: Hypervisor-side OTel receiver

**Status:** complete on `simple-microvm-infra` branch `per-slot-telemetry`, commit `72c0fac`.

**Files:**
- Create: `hosts/hypervisor/otel-collector.nix`
- Modify: `hosts/hypervisor/default.nix` (imports list, after `./telemetry.nix`)

Module runs a hypervisor-local `services.opentelemetry-collector` on `0.0.0.0:4317` (OTLP/gRPC). Metrics pipeline: `memory_limiter → batch → prometheusremotewrite` to `http://127.0.0.1:9090/api/v1/write`. Logs pipeline: `memory_limiter → batch → loki` to `http://127.0.0.1:3100/loki/api/v1/push` with explicit `default_labels_enabled = { exporter = false; job = true; instance = true; level = true; }`.

Adds `services.prometheus.extraFlags = [ "--web.enable-remote-write-receiver" ]` (disabled by default in NixOS's Prometheus module).

Adds systemd ordering: `services.opentelemetry-collector.{after,wants} = [ "prometheus.service" "loki.service" ]` so the receiver doesn't spin on cold-boot retries before its downstream is up.

Notably does **not** use `networking.firewall.interfaces.<iface>.allowedTCPPorts` — that module is disabled on this host (`networking.firewall.enable = false` in `hosts/hypervisor/network.nix`). The real firewall is the nftables ruleset in `network.nix` which already allows bridges + tailscale + lo on the input chain and drops everything on the internet-facing interface by default.

### Task 4: Bump slot1 microvm.mem 8192 → 12288

**Status:** complete on `simple-microvm-infra` branch `per-slot-telemetry`, commit `a95529d`.

**Files:** `flake.nix:57`.

### Task 5: Fix microvm-auto-restart + enable it

**Status:** complete on `simple-microvm-infra` branch `per-slot-telemetry`, commit `f2b4975`.

**Files:**
- Modify: `modules/microvm-auto-restart.nix` — rename `VMS="vm1 vm2 vm3 vm4 vm5"` → `VMS="slot1 slot2 slot3 slot4 slot5"`. Without this, the update script was a no-op.
- Modify: `hosts/hypervisor/comin.nix` — flip `services.microvm-auto-restart.enable = true` and update the comment block.

### Task 6: flake.lock bump (after Tasks 1 & 2 are merged)

**Status:** pending — requires Tasks 1 and 2 to be merged to `main` first.

Run in `simple-microvm-infra`:
```bash
nix flake lock --update-input oclaw-nix --update-input oclaw-nix-public
git add flake.lock
git commit -m "chore: bump oclaw-nix{,-public} flake.lock for slot-telemetry module"
```

### Task 7: Deploy + verify

**Status:** pending until Task 6 lands.

1. Merge `simple-microvm-infra` branch `per-slot-telemetry` to `main` and push.
2. Watch Comin apply on hypervisor (~60s):
   ```bash
   ssh -i ~/.ssh/id_ed25519 root@44.250.235.222 'journalctl -u comin -f'
   ```
3. Confirm hypervisor otelcol is listening and enabled:
   ```bash
   ssh root@44.250.235.222 'systemctl is-active opentelemetry-collector; ss -tlnp | grep 4317'
   ```
4. Confirm slot1 was restarted (it will be — mem changed from 8192→12288):
   ```bash
   ssh root@44.250.235.222 'journalctl -u microvm-auto-update --since "5 min ago" --no-pager | tail'
   ```
5. Confirm slot1 otelcol is running and exporting:
   ```bash
   ssh root@10.1.0.2 'systemctl is-active opentelemetry-collector; journalctl -u opentelemetry-collector -n 30 --no-pager | tail'
   ```
6. Query Prometheus for slot metrics:
   ```bash
   curl -s 'http://44.250.235.222:9090/api/v1/query?query=system_memory_usage{slot_id="slot1"}' | jq .
   ```
   Expect non-empty `result`.
7. Query Loki for slot logs:
   ```bash
   curl -sG 'http://44.250.235.222:3100/loki/api/v1/query_range' \
     --data-urlencode 'query={slot_id="slot1"}' \
     --data-urlencode 'limit=5' | jq '.data.result | length'
   ```
   Expect > 0.

---

## Rollback

If deployment breaks something:
1. `git revert <merge sha>` in `simple-microvm-infra` and push. Comin re-deploys previous config in ~60s. Hypervisor otelcol stops, Prometheus remote_write flag removed, auto-restart turns off.
2. Slot-side collectors stay running (they live in `oclaw-nix`/`oclaw-nix-public`) but harmlessly fail to export once the receiver disappears — OTLP exporter's retry queue handles it; no crash, just error logs. To fully remove, revert the per-slot-repo commits too.

Per-slot collectors are independent — a slot's otelcol failing to push has no effect on its other services. `memory_limiter` prevents OOM amplification.

## Out of scope (explicitly)

- Slots 3–5 are not covered by this plan. They have no per-slot repo and no in-VM Comin. If we want them, add `lib/create-vm.nix` back-wiring in a follow-up.
- No traces pipeline (no instrumented apps yet).
- No per-process metrics (`process` scraper skipped to keep cardinality sane).
- No dashboards — Grafana Explore is enough until we know what we actually want to see.
