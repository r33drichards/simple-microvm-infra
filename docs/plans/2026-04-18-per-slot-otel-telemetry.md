# Per-Slot OTel Telemetry Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship host-level metrics and systemd-journal logs out of every MicroVM slot into the hypervisor's existing Prometheus + Loki stack via OpenTelemetry, so we have visibility into per-slot resource usage (and can catch the kind of guest memory leak that just took down slot1 after 25 days).

**Architecture:**
- Each slot runs `services.opentelemetry-collector` (package: `opentelemetry-collector-contrib`) with `hostmetrics` + `journald` receivers and an OTLP/gRPC exporter pointing at the bridge gateway IP (`10.X.0.1:4317`).
- Hypervisor runs a **second** otelcol that receives OTLP on all bridge IPs and fans out: metrics → `prometheusremotewrite` into the existing Prometheus (port 9090), logs → `loki` exporter into existing Loki (port 3100).
- Firewall: the hypervisor's otelcol listens on `0.0.0.0:4317` but the NixOS firewall only opens port 4317 on `br-slot{1..5}` interfaces — that means slots can push in via bridge, the internet and Tailscale cannot.

**Tech Stack:** NixOS 25.05, `opentelemetry-collector-contrib`, existing Prometheus/Loki on hypervisor, `services.opentelemetry-collector` NixOS module.

**Why push (OTLP) instead of scraping node_exporter?** Single agent per slot handles metrics + logs uniformly; no inbound port on slot; matches the "OTel through firewall" intent; future-extensible (traces). Cost: ~60–80 MB RAM per slot (see Task 5 for the slot1 mem bump).

**Pre-approval decisions (baked in by the requester):**
- Memory: bump slot1 `microvm.mem` from 8192 → 12288 to absorb otelcol + restore headroom after the leak we just saw. Slots 2–5 stay at current values (6144) for now; revisit if they trend hot.
- Deploy path: Comin auto-deploy from `main`; no direct `nixos-rebuild` needed.
- One-way cardinality control: label each slot with `host.name = slot<N>` and `slot.id = slot<N>`; do not emit per-cgroup/process cardinality (skip `process` scraper) — keeps Prometheus tidy.

---

### Task 1: Create the slot-side OTel collector module

**Files:**
- Create: `modules/slot-telemetry.nix`

**Step 1: Write the module**

```nix
# modules/slot-telemetry.nix
# Per-slot OpenTelemetry collector. Emits hostmetrics + journald logs
# via OTLP/gRPC to the hypervisor-side otelcol at <bridge-gateway>:4317.
{ config, lib, pkgs, ... }:

let
  networks = import ./networks.nix;
  slotNet = networks.networks.${config.microvm.network};
  hypervisorGateway = "${slotNet.subnet}.1";
in {
  services.opentelemetry-collector = {
    enable = true;
    package = pkgs.opentelemetry-collector-contrib;
    settings = {
      receivers = {
        hostmetrics = {
          collection_interval = "30s";
          scrapers = {
            cpu = {};
            load = {};
            memory = {};
            disk = {};
            filesystem = {};
            network = {};
            paging = {};
          };
        };
        journald = {
          directory = "/var/log/journal";
          units = [];  # all units; trim later if noisy
          priority = "info";
        };
      };

      processors = {
        batch = {
          timeout = "10s";
          send_batch_size = 1024;
        };
        resource = {
          attributes = [
            { key = "host.name"; value = config.networking.hostName; action = "upsert"; }
            { key = "slot.id";   value = config.networking.hostName; action = "upsert"; }
          ];
        };
        memory_limiter = {
          check_interval = "5s";
          limit_percentage = 75;
          spike_limit_percentage = 20;
        };
      };

      exporters.otlp = {
        endpoint = "${hypervisorGateway}:4317";
        tls.insecure = true;
      };

      service.pipelines = {
        metrics = {
          receivers = [ "hostmetrics" ];
          processors = [ "memory_limiter" "resource" "batch" ];
          exporters = [ "otlp" ];
        };
        logs = {
          receivers = [ "journald" ];
          processors = [ "memory_limiter" "resource" "batch" ];
          exporters = [ "otlp" ];
        };
      };
    };
  };
}
```

**Step 2: Verify syntax**

```bash
cd simple-microvm-infra
nix flake check 2>&1 | head -40
```
Expected: no errors (or only pre-existing warnings).

**Step 3: Commit**

```bash
git add modules/slot-telemetry.nix
git commit -m "feat: add slot-side OTel collector module"
```

---

### Task 2: Wire the slot-telemetry module into every slot via create-vm.nix

**Files:**
- Modify: `lib/create-vm.nix:23-25` (the `imports` list)

**Step 1: Add import**

Change:
```nix
imports = [
  ../modules/slot-vm.nix  # Minimal base config
] ++ modules;
```
To:
```nix
imports = [
  ../modules/slot-vm.nix       # Minimal base config
  ../modules/slot-telemetry.nix # Per-slot OTel collector
] ++ modules;
```

**Step 2: Build slot1 runner locally to verify**

```bash
nix build --no-link .#nixosConfigurations.slot1.config.microvm.declaredRunner 2>&1 | tail -20
```
Expected: successful build, no assertion failures.

**Step 3: Commit**

```bash
git add lib/create-vm.nix
git commit -m "feat: enable slot-telemetry on every slot"
```

---

### Task 3: Create hypervisor-side OTel receiver

**Files:**
- Create: `hosts/hypervisor/otel-collector.nix`
- Modify: `hosts/hypervisor/default.nix` (imports list)

**Step 1: Write the hypervisor receiver**

```nix
# hosts/hypervisor/otel-collector.nix
# Receives OTLP from slot-side otelcol collectors and fans out:
#   metrics -> Prometheus remote_write (port 9090)
#   logs    -> Loki HTTP push (port 3100)
# Listens on 0.0.0.0:4317; firewall only opens the port on br-slot{1..5}.
{ config, pkgs, lib, ... }:

{
  services.opentelemetry-collector = {
    enable = true;
    package = pkgs.opentelemetry-collector-contrib;
    settings = {
      receivers.otlp.protocols = {
        grpc.endpoint = "0.0.0.0:4317";
        # http intentionally omitted — slots only use gRPC
      };

      processors = {
        batch = {
          timeout = "10s";
          send_batch_size = 1024;
        };
        memory_limiter = {
          check_interval = "5s";
          limit_percentage = 75;
          spike_limit_percentage = 20;
        };
      };

      exporters = {
        prometheusremotewrite = {
          endpoint = "http://127.0.0.1:9090/api/v1/write";
          tls.insecure = true;
          # Keep resource labels as Prom labels
          resource_to_telemetry_conversion.enabled = true;
        };
        loki = {
          endpoint = "http://127.0.0.1:3100/loki/api/v1/push";
          default_labels_enabled = {
            exporter = false;
            job = true;
          };
        };
      };

      service.pipelines = {
        metrics = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "batch" ];
          exporters = [ "prometheusremotewrite" ];
        };
        logs = {
          receivers = [ "otlp" ];
          processors = [ "memory_limiter" "batch" ];
          exporters = [ "loki" ];
        };
      };
    };
  };

  # Prometheus must accept remote_write (disabled by default in NixOS module).
  services.prometheus.extraFlags = [
    "--web.enable-remote-write-receiver"
  ];

  # Open 4317 only on the slot bridges — NOT internet-facing, NOT tailscale-facing.
  networking.firewall.interfaces = lib.genAttrs
    [ "br-slot1" "br-slot2" "br-slot3" "br-slot4" "br-slot5" ]
    (_: { allowedTCPPorts = [ 4317 ]; });
}
```

**Step 2: Import from hypervisor default.nix**

In `hosts/hypervisor/default.nix`, add to the `imports` list (after `./telemetry.nix`):
```nix
./otel-collector.nix
```

**Step 3: Build hypervisor to verify**

```bash
nix build --no-link .#nixosConfigurations.hypervisor.config.system.build.toplevel 2>&1 | tail -20
```
Expected: successful build.

**Step 4: Commit**

```bash
git add hosts/hypervisor/otel-collector.nix hosts/hypervisor/default.nix
git commit -m "feat: hypervisor otel receiver, routes slot metrics to Prometheus and logs to Loki"
```

---

### Task 4: Bump slot1 memory

**Files:**
- Modify: `flake.nix:57`

**Step 1: Edit the slot1 entry**

Change:
```nix
slot1 = {
  config = { microvm.mem = 8192; microvm.vcpu = 4; };
  extraModules = [ oclaw-nix.nixosModules.default ];
};
```
To:
```nix
slot1 = {
  config = { microvm.mem = 12288; microvm.vcpu = 4; };
  extraModules = [ oclaw-nix.nixosModules.default ];
};
```

**Step 2: Verify the whole flake still builds**

```bash
nix flake check 2>&1 | tail -10
nix build --no-link .#nixosConfigurations.slot1.config.microvm.declaredRunner 2>&1 | tail -5
```

**Step 3: Commit**

```bash
git add flake.nix
git commit -m "chore: bump slot1 to 12GiB, makes room for otelcol + restores headroom after mem leak"
```

---

### Task 5: Deploy and verify

**Step 1: Push**

```bash
git push origin main
```
Expected: Comin on hypervisor picks up the change within 60s and deploys. Slot1's hypervisor-side runner is rebuilt (new mem allocation + new slot-telemetry module) and the slot is restarted by microvm-auto-restart logic.

**Step 2: Watch Comin**

```bash
ssh -i ~/.ssh/id_ed25519 root@44.250.235.222 'journalctl -u comin -f' &
# Ctrl-C when you see "deployment succeeded"
```

**Step 3: Verify hypervisor otelcol is listening on 4317 on bridges**

```bash
ssh -i ~/.ssh/id_ed25519 root@44.250.235.222 '
  systemctl is-active opentelemetry-collector
  ss -tlnp | grep 4317
  iptables -L nixos-fw -v -n | grep 4317
'
```
Expected: service active; listening on `*:4317`; firewall shows `ACCEPT tcp -- br-slot1 ... dpt:4317` etc.

**Step 4: Verify slot1 collector is running and pushing**

```bash
ssh -i ~/.ssh/id_ed25519 root@10.1.0.2 '
  systemctl is-active opentelemetry-collector
  journalctl -u opentelemetry-collector -n 30 --no-pager | tail
'
```
Expected: active; logs show OTLP exports succeeding (no persistent "connection refused" to `10.1.0.1:4317`).

**Step 5: Verify metrics arriving in Prometheus**

```bash
curl -s 'http://44.250.235.222:9090/api/v1/query?query=system_memory_usage{slot_id="slot1"}' | jq .
```
Expected: non-empty `result` array with a recent `value` tuple.

**Step 6: Verify logs arriving in Loki**

```bash
curl -sG 'http://44.250.235.222:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={slot_id="slot1"}' \
  --data-urlencode 'limit=5' | jq '.data.result | length'
```
Expected: > 0.

**Step 7: Add a minimal Grafana dashboard panel (optional, separate commit)**

Skipped in this plan — user can eyeball metrics in Grafana's Explore view first, then productize dashboards later.

---

## Rollback

If the hypervisor otelcol or Prometheus `--web.enable-remote-write-receiver` breaks scraping:
```bash
git revert <merge sha>
git push
# Comin re-deploys previous config in ~60s
```
Per-slot collectors are independent — a slot's otelcol failing to push has no effect on its other services (memory_limiter prevents OOM amplification).

## Out of scope (explicitly)

- No traces pipeline (no instrumented apps yet). Add receivers + tempo later.
- No process-level metrics (`process` scraper skipped to keep cardinality sane).
- No dashboards — Grafana Explore is enough until we know what we actually want to see.
- No per-service systemd log routing — journald receiver ships everything; Loki queries can filter.
- No changes to slots 2–5 memory budgets.
