# Network Topology and Architecture

This document provides detailed diagrams and explanations of the network architecture for the MicroVM infrastructure.

## Table of Contents
1. [Physical/Virtual Topology](#physicalvirtual-topology)
2. [Network Traffic Flows](#network-traffic-flows)
3. [DNS-Based Allowlist Filtering](#dns-based-allowlist-filtering)
4. [nftables Chain Processing](#nftables-chain-processing)
5. [Isolation Mechanism](#isolation-mechanism)
6. [IP Address Allocation](#ip-address-allocation)
7. [Traffic Flow Examples](#traffic-flow-examples)

---

## Physical/Virtual Topology

```mermaid
graph LR
    subgraph Remote["Remote Access"]
        Laptop["Your Laptop<br/>100.y.y.y<br/>(Tailscale Client)"]
    end

    subgraph Internet["Internet"]
        External["External Hosts"]
        AWS["AWS Network"]
        IMDS["AWS IMDS<br/>169.254.169.254"]
    end

    subgraph Hypervisor["a1.metal Hypervisor (ARM64)"]
        subgraph NetLayer["Network Layer"]
            tailscale0["tailscale0<br/>100.x.x.x<br/>(VPN)"]
            enP2p4s0["enP2p4s0<br/>54.201.157.166<br/>(AWS Physical)"]
        end

        nftables["nftables<br/>• NAT (IMDS, Internet)<br/>• Firewall (Isolation)<br/>• DNS DNAT (port 53)<br/>• Forwarding Rules"]

        CoreDNS["CoreDNS<br/>127.0.0.1:53<br/>• Allowlist Filtering<br/>• Default-Deny Policy"]

        subgraph VMNetwork["VM Network Infrastructure"]
            subgraph Slot1Net["Slot1 Network"]
                br1["br-slot1<br/>10.1.0.1/24"]
                tap1["vm-slot1<br/>(TAP)"]
            end

            subgraph Slot2Net["Slot2 Network"]
                br2["br-slot2<br/>10.2.0.1/24"]
                tap2["vm-slot2<br/>(TAP)"]
            end

            subgraph Slot3Net["Slot3 Network"]
                br3["br-slot3<br/>10.3.0.1/24"]
                tap3["vm-slot3<br/>(TAP)"]
            end

            subgraph Slot4Net["Slot4 Network"]
                br4["br-slot4<br/>10.4.0.1/24"]
                tap4["vm-slot4<br/>(TAP)"]
            end

            subgraph Slot5Net["Slot5 Network"]
                br5["br-slot5<br/>10.5.0.1/24"]
                tap5["vm-slot5<br/>(TAP)"]
            end
        end
    end

    subgraph Slots["Slots (Fixed Network Identity)"]
        Slot1["Slot1<br/>10.1.0.2/24<br/>(NixOS)"]
        Slot2["Slot2<br/>10.2.0.2/24<br/>(NixOS)"]
        Slot3["Slot3<br/>10.3.0.2/24<br/>(NixOS)"]
        Slot4["Slot4<br/>10.4.0.2/24<br/>(NixOS)"]
        Slot5["Slot5<br/>10.5.0.2/24<br/>(NixOS)"]
    end

    %% Remote to Internet
    Laptop <-.VPN Tunnel.-> External

    %% Internet to Hypervisor
    External -.Tailscale.-> tailscale0
    AWS <--> enP2p4s0
    IMDS <--> enP2p4s0

    %% Network interfaces to nftables
    tailscale0 <--> nftables
    enP2p4s0 <--> nftables

    %% DNS filtering
    nftables -.DNS DNAT.-> CoreDNS

    %% nftables to bridges (organized to avoid crossings)
    nftables <--> br1
    nftables <--> br2
    nftables <--> br3
    nftables <--> br4
    nftables <--> br5

    %% Bridges to TAPs (within each network)
    br1 --- tap1
    br2 --- tap2
    br3 --- tap3
    br4 --- tap4
    br5 --- tap5

    %% TAPs to Slots (virtio-net)
    tap1 -.virtio-net.-> Slot1
    tap2 -.virtio-net.-> Slot2
    tap3 -.virtio-net.-> Slot3
    tap4 -.virtio-net.-> Slot4
    tap5 -.virtio-net.-> Slot5

    style Remote fill:#f3e5f5
    style Internet fill:#e1f5ff
    style Hypervisor fill:#fff4e1
    style NetLayer fill:#fff9e6
    style nftables fill:#ffebee
    style CoreDNS fill:#e1f5fe
    style VMNetwork fill:#f5f5f5
    style Slot1Net fill:#e3f2fd
    style Slot2Net fill:#e8f5e9
    style Slot3Net fill:#fff3e0
    style Slot4Net fill:#fce4ec
    style Slot5Net fill:#f1f8e9
    style Slots fill:#e8f5e9
```

---

## Network Traffic Flows

### Flow 1: Slot to Internet

```mermaid
sequenceDiagram
    participant Slot1 as Slot1<br/>(10.1.0.2)
    participant GW as br-slot1<br/>(10.1.0.1)
    participant NFT as nftables
    participant WAN as enP2p4s0<br/>(Public IP)
    participant Internet

    Slot1->>GW: TCP to 8.8.8.8:443<br/>src: 10.1.0.2:1234
    GW->>NFT: Forward chain check
    Note over NFT: Rule: iifname br-slot1<br/>oifname enP2p4s0<br/>ACCEPT ✅
    NFT->>NFT: Postrouting NAT
    Note over NFT: Masquerade<br/>10.1.0.2 → Public IP
    NFT->>WAN: src: Public IP:1234<br/>dst: 8.8.8.8:443
    WAN->>Internet: Routed via AWS
    Internet-->>WAN: Response
    WAN-->>NFT: src: 8.8.8.8:443<br/>dst: Public IP:1234
    Note over NFT: Connection tracking:<br/>established connection ✅
    NFT-->>NFT: Reverse NAT<br/>Public IP → 10.1.0.2
    NFT-->>GW: dst: 10.1.0.2:1234
    GW-->>Slot1: Response delivered
```

### Flow 2: Slot to AWS IMDS (Metadata Service)

```mermaid
sequenceDiagram
    participant Slot1 as Slot1<br/>(10.1.0.2)
    participant GW as br-slot1<br/>(10.1.0.1)
    participant NFT as nftables
    participant IMDS as AWS IMDS<br/>(169.254.169.254)

    Slot1->>GW: GET http://169.254.169.254/latest/meta-data/<br/>src: 10.1.0.2:5678
    GW->>NFT: Prerouting DNAT
    Note over NFT: Rule: ip saddr 10.0.0.0/8<br/>ip daddr 169.254.169.254<br/>DNAT to 169.254.169.254:80
    NFT->>NFT: Postrouting NAT
    Note over NFT: Masquerade<br/>10.1.0.2 → Hypervisor IP<br/>(IMDS only responds to local traffic)
    NFT->>IMDS: src: Hypervisor IP:5678<br/>dst: 169.254.169.254:80
    IMDS-->>NFT: Response with metadata
    NFT-->>NFT: Reverse NAT<br/>Hypervisor IP → 10.1.0.2
    NFT-->>GW: dst: 10.1.0.2:5678
    GW-->>Slot1: Metadata delivered
```

### Flow 3: Remote Access via Tailscale

```mermaid
sequenceDiagram
    participant Laptop as Your Laptop<br/>(100.y.y.y)
    participant TS as tailscale0<br/>(100.x.x.x)
    participant NFT as nftables
    participant GW as br-slot1<br/>(10.1.0.1)
    participant Slot1 as Slot1<br/>(10.1.0.2)

    Note over Laptop,Slot1: SSH to Slot1 via Tailscale subnet route
    Laptop->>TS: SSH to 10.1.0.2:22<br/>src: 100.y.y.y
    TS->>NFT: Forward chain check
    Note over NFT: Rule: iifname tailscale0<br/>oifname br-slot1<br/>ACCEPT ✅
    NFT->>GW: Forward to Slot1
    GW->>Slot1: SSH connection
    Slot1-->>GW: SSH response
    GW-->>NFT: Return traffic
    Note over NFT: Connection tracking:<br/>established connection ✅
    NFT-->>TS: Forward response
    TS-->>Laptop: SSH session established
```

### Flow 4: Slot1 to Slot2 (BLOCKED - Isolation)

```mermaid
sequenceDiagram
    participant Slot1 as Slot1<br/>(10.1.0.2)
    participant GW1 as br-slot1<br/>(10.1.0.1)
    participant NFT as nftables
    participant GW2 as br-slot2<br/>(10.2.0.1)
    participant Slot2 as Slot2<br/>(10.2.0.2)

    Slot1->>GW1: Ping 10.2.0.2<br/>src: 10.1.0.2
    GW1->>NFT: Forward chain check
    Note over NFT: Rule: iifname br-slot1<br/>oifname br-slot2<br/>DROP ❌
    NFT->>NFT: Log: "FORWARD DROP"
    NFT--xGW2: Packet dropped
    Note over Slot1: Connection timeout<br/>(no response)
```

### Flow 5: DNS Query (Allowed Domain)

```mermaid
sequenceDiagram
    participant Slot1 as Slot1<br/>(10.1.0.2)
    participant GW as br-slot1<br/>(10.1.0.1)
    participant NFT as nftables
    participant DNS as CoreDNS<br/>(127.0.0.1:53)
    participant Upstream as Upstream DNS<br/>(1.1.1.1)

    Note over Slot1: nslookup github.com
    Slot1->>GW: DNS query: github.com<br/>src: 10.1.0.2:54321<br/>dst: 10.1.0.1:53
    GW->>NFT: Prerouting chain
    Note over NFT: DNAT Rule:<br/>iifname br-slot* udp dport 53<br/>dnat to 127.0.0.1:53
    NFT->>DNS: DNS query redirected<br/>dst: 127.0.0.1:53
    Note over DNS: Domain "github.com"<br/>matches allowlist ✅
    DNS->>Upstream: Forward query to 1.1.1.1
    Upstream-->>DNS: Response: 140.82.112.3
    DNS-->>NFT: DNS response
    Note over NFT: Connection tracking:<br/>reverse NAT
    NFT-->>GW: Response to 10.1.0.2
    GW-->>Slot1: github.com = 140.82.112.3 ✅
```

### Flow 6: DNS Query (Blocked Domain)

```mermaid
sequenceDiagram
    participant Slot1 as Slot1<br/>(10.1.0.2)
    participant GW as br-slot1<br/>(10.1.0.1)
    participant NFT as nftables
    participant DNS as CoreDNS<br/>(127.0.0.1:53)

    Note over Slot1: nslookup malicious-site.com
    Slot1->>GW: DNS query: malicious-site.com<br/>src: 10.1.0.2:54322<br/>dst: 10.1.0.1:53
    GW->>NFT: Prerouting chain
    Note over NFT: DNAT Rule:<br/>iifname br-slot* udp dport 53<br/>dnat to 127.0.0.1:53
    NFT->>DNS: DNS query redirected
    Note over DNS: Domain "malicious-site.com"<br/>NOT in allowlist ❌
    DNS->>DNS: Log: denial
    DNS-->>NFT: NXDOMAIN response
    NFT-->>GW: Response to 10.1.0.2
    GW-->>Slot1: NXDOMAIN (domain not found) ❌
    Note over Slot1: Resolution failed<br/>(cannot connect)
```

---

## DNS-Based Allowlist Filtering

The infrastructure implements DNS-based egress filtering using CoreDNS. This provides a default-deny policy where slots can only resolve domains on an explicit allowlist.

### Architecture Overview

```mermaid
graph TB
    subgraph Slots["Slots (Fixed Network Identity)"]
        Slot1["Slot1<br/>DNS: 10.1.0.1"]
        Slot2["Slot2<br/>DNS: 10.2.0.1"]
        Slot3["Slot3<br/>DNS: 10.3.0.1"]
    end

    subgraph Hypervisor["Hypervisor"]
        subgraph Bridges["Slot Bridges"]
            BR1["br-slot1<br/>10.1.0.1"]
            BR2["br-slot2<br/>10.2.0.1"]
            BR3["br-slot3<br/>10.3.0.1"]
        end

        NFT["nftables<br/>DNAT port 53<br/>→ 127.0.0.1:53"]

        subgraph CoreDNS["CoreDNS (127.0.0.1:53)"]
            Allowlist["Allowlist Check"]
            Forward["Forward to Upstream"]
            Deny["Return NXDOMAIN"]
        end
    end

    subgraph Upstream["Upstream DNS"]
        CF["Cloudflare<br/>1.1.1.1"]
        Google["Google<br/>8.8.8.8"]
    end

    Slot1 -->|DNS query| BR1
    Slot2 -->|DNS query| BR2
    Slot3 -->|DNS query| BR3

    BR1 --> NFT
    BR2 --> NFT
    BR3 --> NFT

    NFT -->|Redirect| Allowlist
    Allowlist -->|Allowed| Forward
    Allowlist -->|Blocked| Deny

    Forward --> CF
    Forward --> Google

    style Slots fill:#e8f5e9
    style Hypervisor fill:#fff4e1
    style CoreDNS fill:#e1f5fe
    style Upstream fill:#f3e5f5
    style Deny fill:#ffcdd2
```

### How DNS Filtering Works

1. **Slot Configuration**: Each slot is configured to use its gateway IP (10.x.0.1) as the DNS resolver
2. **Transparent Interception**: nftables DNAT rules intercept ALL port 53 traffic from slot bridges
3. **Redirection to localhost**: DNS queries are redirected to CoreDNS running on 127.0.0.1:53
4. **Allowlist Check**: CoreDNS checks if the domain is in the allowlist
5. **Forward or Deny**: Allowed domains are forwarded to upstream; blocked domains get NXDOMAIN

### nftables DNAT Rules

```nft
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat;

        # Redirect all DNS traffic from slots to CoreDNS
        iifname { "br-slot1", "br-slot2", "br-slot3", "br-slot4", "br-slot5" } udp dport 53 dnat to 127.0.0.1:53
        iifname { "br-slot1", "br-slot2", "br-slot3", "br-slot4", "br-slot5" } tcp dport 53 dnat to 127.0.0.1:53
    }
}

table inet filter {
    chain forward {
        # Block DNS-over-TLS to prevent bypass
        iifname { "br-slot1", "br-slot2", "br-slot3", "br-slot4", "br-slot5" } tcp dport 853 drop
    }
}
```

**Key Points:**
- Both UDP and TCP DNS are redirected
- DNS-over-TLS (port 853) is explicitly blocked to prevent bypass
- Requires `net.ipv4.conf.all.route_localnet = 1` to allow DNAT to 127.0.0.1

### CoreDNS Configuration

CoreDNS uses a per-domain forward block configuration:

```corefile
# Allowed domain example
github.com:53 {
    bind 127.0.0.1
    forward . 1.1.1.1 8.8.8.8
    cache 300
    log
}

# Default-deny catch-all
.:53 {
    bind 127.0.0.1
    log . {
        class denial
    }
    template ANY ANY {
        rcode NXDOMAIN
    }
}
```

### Allowlist Categories

The allowlist includes domains organized by category:

| Category | Example Domains | Purpose |
|----------|-----------------|---------|
| **Package Registries** | `registry.npmjs.org`, `pypi.org`, `crates.io` | Package downloads |
| **Code Hosting** | `github.com`, `gitlab.com`, `bitbucket.org` | Source code, git operations |
| **Container Registries** | `docker.io`, `ghcr.io`, `quay.io` | Container images |
| **CDNs** | `cloudflare.com`, `fastly.com`, `jsdelivr.net` | Static assets |
| **Linux Repos** | `archive.ubuntu.com`, `deb.debian.org` | System packages |
| **AI Services** | `api.anthropic.com`, `api.openai.com` | AI API access |
| **NixOS** | `cache.nixos.org`, `channels.nixos.org` | Nix packages |
| **Cloud Providers** | `s3.amazonaws.com`, `storage.googleapis.com` | Cloud storage |
| **VPN** | `tailscale.com`, `controlplane.tailscale.com` | VPN connectivity |

**Total Allowed Domains:** ~177 domains (with automatic subdomain coverage)

### DNS Query Flow

```mermaid
graph LR
    subgraph Slot["Slot (10.x.0.2)"]
        App["Application"]
    end

    subgraph Gateway["Gateway (10.x.0.1)"]
        Bridge["br-slotX"]
    end

    subgraph Prerouting["nftables Prerouting"]
        DNAT["DNAT<br/>→ 127.0.0.1:53"]
    end

    subgraph CoreDNS["CoreDNS"]
        Check{In Allowlist?}
        Forward["Forward to<br/>1.1.1.1 / 8.8.8.8"]
        Block["NXDOMAIN"]
    end

    subgraph Upstream["Upstream DNS"]
        Resolver["1.1.1.1"]
    end

    App -->|DNS query<br/>port 53| Bridge
    Bridge --> DNAT
    DNAT --> Check
    Check -->|Yes| Forward
    Check -->|No| Block
    Forward --> Resolver
    Resolver -->|IP address| Forward
    Forward -->|Response| App
    Block -->|NXDOMAIN| App

    style Block fill:#ffcdd2
    style Forward fill:#c8e6c9
    style Slot fill:#e8f5e9
```

### Security Benefits

1. **Default-Deny Policy**: Only explicitly allowed domains can be resolved
2. **Transparent Enforcement**: Slots cannot bypass filtering - all DNS is intercepted at network layer
3. **DoT Prevention**: DNS-over-TLS is blocked to prevent encrypted DNS bypass
4. **Audit Logging**: All DNS queries (allowed and denied) are logged
5. **Subdomain Coverage**: Allowing `github.com` automatically covers `*.github.com`

### Bypass Prevention

The filtering cannot be bypassed by slots because:

| Bypass Attempt | Prevention |
|----------------|------------|
| Use different DNS server (e.g., 8.8.8.8 directly) | All port 53 traffic is DNAT'd to CoreDNS |
| Use DNS-over-TLS (port 853) | Port 853 is explicitly blocked |
| Use DNS-over-HTTPS (DoH) | Would require HTTPS to a blocked domain |
| Hardcode IP addresses | Only works if attacker knows IPs in advance |

### Troubleshooting DNS Filtering

```bash
# Check CoreDNS status
systemctl status coredns

# View DNS query logs
journalctl -u coredns -f

# Test DNS resolution from slot
ssh 10.1.0.2 "nslookup github.com"      # Should resolve
ssh 10.1.0.2 "nslookup evil-site.com"   # Should fail with NXDOMAIN

# Verify DNAT rules
nft list chain ip nat prerouting

# Check if port 853 is blocked
ssh 10.1.0.2 "nc -zv 1.1.1.1 853"       # Should timeout/fail
```

---

## nftables Chain Processing

```mermaid
graph TB
    subgraph Packet["Incoming Packet"]
        PKT[Packet Arrives]
    end

    subgraph Routing["Routing Decision"]
        ROUTE{Destination?}
    end

    subgraph Input["INPUT Chain (to Hypervisor)"]
        INPUT_POLICY["Policy: DROP"]
        INPUT_ESTAB{Established/<br/>Related?}
        INPUT_LO{Loopback?}
        INPUT_TS{Tailscale?}
        INPUT_SSH{SSH<br/>port 22?}
        INPUT_BRIDGE{From VM<br/>bridge?}
        INPUT_LOG[Log & Drop]
        INPUT_ACCEPT[ACCEPT]
    end

    subgraph Forward["FORWARD Chain (through Hypervisor)"]
        FWD_POLICY["Policy: DROP"]
        FWD_ESTAB{Established/<br/>Related?}
        FWD_ISOLATE{Inter-Slot?<br/>br-slotX → br-slotY}
        FWD_TS_VM{Tailscale<br/>→ Slot?}
        FWD_VM_WAN{Slot → Internet?}
        FWD_WAN_VM{Internet → Slot?}
        FWD_LOG[Log & Drop]
        FWD_ACCEPT[ACCEPT]
        FWD_DROP[DROP]
    end

    subgraph NAT_Pre["PREROUTING (NAT)"]
        PRE_DNS{DNS<br/>port 53?}
        PRE_DNS_DNAT[DNAT to<br/>127.0.0.1:53<br/>CoreDNS]
        PRE_IMDS{IMDS<br/>request?}
        PRE_DNAT[DNAT to<br/>169.254.169.254]
        PRE_CONTINUE[Continue]
    end

    subgraph NAT_Post["POSTROUTING (NAT)"]
        POST_IMDS{IMDS<br/>traffic?}
        POST_WAN{VM → Internet?}
        POST_MASQ[Masquerade]
        POST_CONTINUE[Continue]
    end

    PKT --> PRE_DNS
    PRE_DNS -->|Yes| PRE_DNS_DNAT
    PRE_DNS -->|No| PRE_IMDS
    PRE_DNS_DNAT --> ROUTE
    PRE_IMDS -->|Yes| PRE_DNAT
    PRE_IMDS -->|No| PRE_CONTINUE
    PRE_DNAT --> ROUTE
    PRE_CONTINUE --> ROUTE

    ROUTE -->|Local| INPUT_POLICY
    ROUTE -->|Forward| FWD_POLICY

    INPUT_POLICY --> INPUT_ESTAB
    INPUT_ESTAB -->|Yes| INPUT_ACCEPT
    INPUT_ESTAB -->|No| INPUT_LO
    INPUT_LO -->|Yes| INPUT_ACCEPT
    INPUT_LO -->|No| INPUT_TS
    INPUT_TS -->|Yes| INPUT_ACCEPT
    INPUT_TS -->|No| INPUT_SSH
    INPUT_SSH -->|Yes| INPUT_ACCEPT
    INPUT_SSH -->|No| INPUT_BRIDGE
    INPUT_BRIDGE -->|Yes| INPUT_ACCEPT
    INPUT_BRIDGE -->|No| INPUT_LOG

    FWD_POLICY --> FWD_ESTAB
    FWD_ESTAB -->|Yes| FWD_ACCEPT
    FWD_ESTAB -->|No| FWD_ISOLATE
    FWD_ISOLATE -->|Yes| FWD_DROP
    FWD_ISOLATE -->|No| FWD_TS_VM
    FWD_TS_VM -->|Yes| FWD_ACCEPT
    FWD_TS_VM -->|No| FWD_VM_WAN
    FWD_VM_WAN -->|Yes| FWD_ACCEPT
    FWD_VM_WAN -->|No| FWD_WAN_VM
    FWD_WAN_VM -->|Yes + Estab| FWD_ACCEPT
    FWD_WAN_VM -->|No| FWD_LOG

    FWD_ACCEPT --> POST_IMDS
    INPUT_ACCEPT --> POST_IMDS

    POST_IMDS -->|Yes| POST_MASQ
    POST_IMDS -->|No| POST_WAN
    POST_WAN -->|Yes| POST_MASQ
    POST_WAN -->|No| POST_CONTINUE

    style Input fill:#e3f2fd
    style Forward fill:#fff3e0
    style NAT_Pre fill:#f3e5f5
    style NAT_Post fill:#e8f5e9
    style FWD_DROP fill:#ffcdd2
    style INPUT_LOG fill:#ffcdd2
    style PRE_DNS_DNAT fill:#e1f5fe
```

---

## Isolation Mechanism

### How Slot Isolation Works

The `generateIsolationRules` function creates a rule matrix:

```
Source → Target      br-slot1  br-slot2  br-slot3  br-slot4  br-slot5
──────────────────────────────────────────────────────────────────────
br-slot1                 -        DROP      DROP      DROP      DROP
br-slot2               DROP         -       DROP      DROP      DROP
br-slot3               DROP       DROP        -       DROP      DROP
br-slot4               DROP       DROP      DROP        -       DROP
br-slot5               DROP       DROP      DROP      DROP        -
```

**Generated nftables rules:**
```nft
iifname "br-slot1" oifname "br-slot2" drop
iifname "br-slot1" oifname "br-slot3" drop
iifname "br-slot1" oifname "br-slot4" drop
iifname "br-slot1" oifname "br-slot5" drop
iifname "br-slot2" oifname "br-slot1" drop
iifname "br-slot2" oifname "br-slot3" drop
# ... (continues for all combinations)
```

**Result:** Slots cannot communicate with each other at Layer 2 or Layer 3. All inter-slot traffic is dropped at the hypervisor's forward chain.

### Isolation Benefits

```mermaid
graph LR
    subgraph Slot1_Net["Slot1 Network (10.1.0.0/24)"]
        Slot1["Slot1<br/>10.1.0.2"]
    end

    subgraph Slot2_Net["Slot2 Network (10.2.0.0/24)"]
        Slot2["Slot2<br/>10.2.0.2"]
    end

    subgraph Slot3_Net["Slot3 Network (10.3.0.0/24)"]
        Slot3["Slot3<br/>10.3.0.2"]
    end

    Hypervisor["Hypervisor<br/>(nftables isolation)"]

    Slot1 -.->|"❌ BLOCKED"| Hypervisor
    Hypervisor -.->|"❌ BLOCKED"| Slot2
    Slot1 -.->|"❌ BLOCKED"| Slot3
    Slot2 -.->|"❌ BLOCKED"| Slot3

    style Slot1_Net fill:#ffebee
    style Slot2_Net fill:#e8f5e9
    style Slot3_Net fill:#e3f2fd
    style Hypervisor fill:#fff3e0
```

**Security Benefits:**
- **Attack Surface Reduction**: Compromised slot cannot pivot to other slots
- **Traffic Isolation**: Each slot's traffic is completely isolated
- **Independent Policies**: Can apply different security policies per slot
- **Compliance**: Meets multi-tenant isolation requirements

---

## IP Address Allocation

### Address Ranges

| Network | Subnet | Bridge IP | Slot IP | Gateway | Broadcast | Usable IPs |
|---------|--------|-----------|---------|---------|-----------|------------|
| Slot1 | 10.1.0.0/24 | 10.1.0.1 | 10.1.0.2 | 10.1.0.1 | 10.1.0.255 | 10.1.0.2-254 |
| Slot2 | 10.2.0.0/24 | 10.2.0.1 | 10.2.0.2 | 10.2.0.1 | 10.2.0.255 | 10.2.0.2-254 |
| Slot3 | 10.3.0.0/24 | 10.3.0.1 | 10.3.0.2 | 10.3.0.1 | 10.3.0.255 | 10.3.0.2-254 |
| Slot4 | 10.4.0.0/24 | 10.4.0.1 | 10.4.0.2 | 10.4.0.1 | 10.4.0.255 | 10.4.0.2-254 |
| Slot5 | 10.5.0.0/24 | 10.5.0.1 | 10.5.0.2 | 10.5.0.1 | 10.5.0.255 | 10.5.0.2-254 |

### Reserved Addresses

- **10.0.0.0/8**: Entire private range used for slots
- **169.254.169.254**: AWS Instance Metadata Service (IMDS)
- **100.x.x.x/8**: Tailscale CGNAT range (VPN)

### Static IP Configuration

Slots use static IP configuration (no DHCP):

**In slot (systemd-networkd config):**
```nix
systemd.network.networks."10-lan" = {
  matchConfig.Type = "ether";
  address = [ "10.1.0.2/24" ];
  gateway = [ "10.1.0.1" ];
  dns = [ "10.1.0.1" ];  # Points to gateway for DNS filtering
};
```

**Benefits:**
- Predictable IP addresses
- No DHCP server needed
- Faster boot times
- Simplified troubleshooting
- DNS queries routed through allowlist filtering

---

## Traffic Flow Examples

### Example 1: Slot1 Downloads Package from Internet

```mermaid
sequenceDiagram
    autonumber
    participant Slot1 as Slot1<br/>(10.1.0.2)
    participant BR1 as br-slot1<br/>(10.1.0.1)
    participant NFT as nftables
    participant WAN as enP2p4s0
    participant Server as archive.ubuntu.com

    Note over Slot1: curl http://archive.ubuntu.com/package.deb
    Slot1->>BR1: TCP SYN<br/>src: 10.1.0.2:4567<br/>dst: archive.ubuntu.com:80
    BR1->>NFT: Forward chain: iifname br-slot1
    NFT->>NFT: Check isolation rules (pass)
    NFT->>NFT: Check Slot→WAN rule (ACCEPT)
    NFT->>NFT: Postrouting: Masquerade<br/>10.1.0.2 → Public IP
    NFT->>WAN: src: Public IP:4567<br/>dst: archive.ubuntu.com:80
    WAN->>Server: HTTP GET /package.deb
    Server-->>WAN: HTTP 200 OK + package data
    WAN-->>NFT: dst: Public IP:4567
    NFT-->>NFT: Connection tracking: match<br/>Reverse NAT: Public IP → 10.1.0.2
    NFT-->>BR1: dst: 10.1.0.2:4567
    BR1-->>Slot1: Package downloaded ✅
```

### Example 2: SSH from Laptop to Slot3 via Tailscale

```mermaid
sequenceDiagram
    autonumber
    participant Laptop as Laptop<br/>(100.50.50.50)
    participant TS as Tailscale Network
    participant HV_TS as tailscale0<br/>(100.100.100.100)
    participant NFT as nftables
    participant BR3 as br-slot3<br/>(10.3.0.1)
    participant Slot3 as Slot3<br/>(10.3.0.2)

    Note over Laptop: ssh 10.3.0.2
    Laptop->>TS: Encrypted WireGuard tunnel
    TS->>HV_TS: Route via subnet routes
    HV_TS->>NFT: Forward chain: iifname tailscale0<br/>oifname br-slot3
    NFT->>NFT: Check tailscale→Slot rule (ACCEPT)
    NFT->>BR3: Forward to 10.3.0.2:22
    BR3->>Slot3: SSH handshake
    Slot3-->>BR3: SSH response
    BR3-->>NFT: Connection tracking: established
    NFT-->>HV_TS: Return traffic
    HV_TS-->>TS: WireGuard tunnel
    TS-->>Laptop: SSH session established ✅
```

### Example 3: Slot2 Tries to Access Slot4 (Blocked)

```mermaid
sequenceDiagram
    autonumber
    participant Slot2 as Slot2<br/>(10.2.0.2)
    participant BR2 as br-slot2<br/>(10.2.0.1)
    participant NFT as nftables
    participant BR4 as br-slot4<br/>(10.4.0.1)
    participant Slot4 as Slot4<br/>(10.4.0.2)

    Note over Slot2: ping 10.4.0.2
    Slot2->>BR2: ICMP Echo Request<br/>src: 10.2.0.2<br/>dst: 10.4.0.2
    BR2->>NFT: Forward chain: iifname br-slot2<br/>oifname br-slot4
    NFT->>NFT: Match isolation rule:<br/>iifname "br-slot2" oifname "br-slot4" drop
    NFT->>NFT: Log: "FORWARD DROP: br-slot2→br-slot4"
    Note over NFT: Packet dropped ❌
    Note over Slot2: ping timeout<br/>(no response received)
```

### Example 4: Slot5 Accesses AWS IMDS

```mermaid
sequenceDiagram
    autonumber
    participant Slot5 as Slot5<br/>(10.5.0.2)
    participant BR5 as br-slot5<br/>(10.5.0.1)
    participant NFT_PRE as nftables<br/>(Prerouting)
    participant NFT_POST as nftables<br/>(Postrouting)
    participant IMDS as AWS IMDS<br/>(169.254.169.254)

    Note over Slot5: curl http://169.254.169.254/latest/meta-data/instance-id
    Slot5->>BR5: HTTP GET<br/>src: 10.5.0.2:8888<br/>dst: 169.254.169.254:80
    BR5->>NFT_PRE: Prerouting chain
    NFT_PRE->>NFT_PRE: Match: ip saddr 10.0.0.0/8<br/>ip daddr 169.254.169.254
    NFT_PRE->>NFT_PRE: DNAT: keep dst as 169.254.169.254
    NFT_PRE->>NFT_POST: Postrouting chain
    NFT_POST->>NFT_POST: Masquerade:<br/>10.5.0.2 → Hypervisor local IP<br/>(IMDS only responds to local requests)
    NFT_POST->>IMDS: src: Hypervisor IP<br/>dst: 169.254.169.254:80
    IMDS-->>NFT_POST: Instance ID response
    NFT_POST-->>NFT_POST: Reverse NAT:<br/>Hypervisor IP → 10.5.0.2
    NFT_POST-->>BR5: dst: 10.5.0.2:8888
    BR5-->>Slot5: Instance metadata ✅
```

---

## Key Takeaways

### Architecture Principles

1. **Defense in Depth**: Multiple layers of isolation (bridges, nftables, DNS filtering, connection tracking)
2. **Least Privilege**: Default deny policies with explicit allow rules
3. **Network Segmentation**: Each slot in its own /24 subnet
4. **Stateful Inspection**: Connection tracking for return traffic
5. **Atomic Configuration**: All nftables rules update together (no partial states)
6. **DNS-Based Egress Control**: Allowlist filtering prevents unauthorized external access
7. **Portable State**: States can be snapshotted and migrated between slots

### Operational Notes

**Adding a new slot:**
1. Add network definition to `modules/networks.nix`
2. Configuration automatically generates bridge, TAP, isolation rules
3. No manual firewall rule updates needed

**Troubleshooting network issues:**
```bash
# View nftables ruleset
nft list ruleset

# Monitor traffic on bridge
tcpdump -i br-slot1 -n

# Check NAT translations
nft list table ip nat

# View dropped packets
journalctl -k | grep "FORWARD DROP"

# Test connectivity from slot
ssh 10.1.0.2 "ping -c 3 8.8.8.8"
```

**Troubleshooting DNS filtering:**
```bash
# Check CoreDNS service status
systemctl status coredns

# View DNS query logs (allowed and denied)
journalctl -u coredns -f

# Test allowed domain resolution
ssh 10.1.0.2 "nslookup github.com"

# Test blocked domain (should return NXDOMAIN)
ssh 10.1.0.2 "nslookup blocked-site.com"

# Verify DNS DNAT rules
nft list chain ip nat prerouting | grep "dport 53"

# Check if DoT is blocked
ssh 10.1.0.2 "timeout 3 nc -zv 1.1.1.1 853"
```

**Performance Considerations:**
- TAP interfaces: ~10-40 Gbps throughput
- nftables: Negligible overhead (<1% CPU)
- Connection tracking: Handles 100k+ concurrent connections
- Bridge forwarding: Wire-speed within hypervisor

---

## References

- **nftables wiki**: https://wiki.nftables.org/
- **CoreDNS documentation**: https://coredns.io/manual/toc/
- **CoreDNS plugins**: https://coredns.io/plugins/
- **systemd-networkd**: https://www.freedesktop.org/software/systemd/man/systemd.network.html
- **Linux bridge**: https://wiki.linuxfoundation.org/networking/bridge
- **Tailscale subnet routes**: https://tailscale.com/kb/1019/subnets/
- **AWS IMDS**: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
