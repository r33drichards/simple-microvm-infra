# Network Topology and Architecture

This document provides detailed diagrams and explanations of the network architecture for the MicroVM infrastructure.

## Table of Contents
1. [Physical/Virtual Topology](#physicalvirtual-topology)
2. [Network Traffic Flows](#network-traffic-flows)
3. [nftables Chain Processing](#nftables-chain-processing)
4. [Isolation Mechanism](#isolation-mechanism)
5. [IP Address Allocation](#ip-address-allocation)
6. [Traffic Flow Examples](#traffic-flow-examples)

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

        nftables["nftables<br/>• NAT (IMDS, Internet)<br/>• Firewall (Isolation)<br/>• Forwarding Rules"]

        subgraph VMNetwork["VM Network Infrastructure"]
            subgraph VM1Net["VM1 Network"]
                br1["br-vm1<br/>10.1.0.1/24"]
                tap1["vm-vm1<br/>(TAP)"]
            end

            subgraph VM2Net["VM2 Network"]
                br2["br-vm2<br/>10.2.0.1/24"]
                tap2["vm-vm2<br/>(TAP)"]
            end

            subgraph VM3Net["VM3 Network"]
                br3["br-vm3<br/>10.3.0.1/24"]
                tap3["vm-vm3<br/>(TAP)"]
            end

            subgraph VM4Net["VM4 Network"]
                br4["br-vm4<br/>10.4.0.1/24"]
                tap4["vm-vm4<br/>(TAP)"]
            end

            subgraph VM5Net["VM5 Network"]
                br5["br-vm5<br/>10.5.0.1/24"]
                tap5["vm-vm5<br/>(TAP)"]
            end
        end
    end

    subgraph VMs["Virtual Machines"]
        VM1["VM1<br/>10.1.0.2/24<br/>(NixOS)"]
        VM2["VM2<br/>10.2.0.2/24<br/>(NixOS)"]
        VM3["VM3<br/>10.3.0.2/24<br/>(NixOS)"]
        VM4["VM4<br/>10.4.0.2/24<br/>(NixOS)"]
        VM5["VM5<br/>10.5.0.2/24<br/>(NixOS)"]
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

    %% TAPs to VMs (virtio-net)
    tap1 -.virtio-net.-> VM1
    tap2 -.virtio-net.-> VM2
    tap3 -.virtio-net.-> VM3
    tap4 -.virtio-net.-> VM4
    tap5 -.virtio-net.-> VM5

    style Remote fill:#f3e5f5
    style Internet fill:#e1f5ff
    style Hypervisor fill:#fff4e1
    style NetLayer fill:#fff9e6
    style nftables fill:#ffebee
    style VMNetwork fill:#f5f5f5
    style VM1Net fill:#e3f2fd
    style VM2Net fill:#e8f5e9
    style VM3Net fill:#fff3e0
    style VM4Net fill:#fce4ec
    style VM5Net fill:#f1f8e9
    style VMs fill:#e8f5e9
```

---

## Network Traffic Flows

### Flow 1: VM to Internet

```mermaid
sequenceDiagram
    participant VM1 as VM1<br/>(10.1.0.2)
    participant GW as br-vm1<br/>(10.1.0.1)
    participant NFT as nftables
    participant WAN as enP2p4s0<br/>(Public IP)
    participant Internet

    VM1->>GW: TCP to 8.8.8.8:443<br/>src: 10.1.0.2:1234
    GW->>NFT: Forward chain check
    Note over NFT: Rule: iifname br-vm1<br/>oifname enP2p4s0<br/>ACCEPT ✅
    NFT->>NFT: Postrouting NAT
    Note over NFT: Masquerade<br/>10.1.0.2 → Public IP
    NFT->>WAN: src: Public IP:1234<br/>dst: 8.8.8.8:443
    WAN->>Internet: Routed via AWS
    Internet-->>WAN: Response
    WAN-->>NFT: src: 8.8.8.8:443<br/>dst: Public IP:1234
    Note over NFT: Connection tracking:<br/>established connection ✅
    NFT-->>NFT: Reverse NAT<br/>Public IP → 10.1.0.2
    NFT-->>GW: dst: 10.1.0.2:1234
    GW-->>VM1: Response delivered
```

### Flow 2: VM to AWS IMDS (Metadata Service)

```mermaid
sequenceDiagram
    participant VM1 as VM1<br/>(10.1.0.2)
    participant GW as br-vm1<br/>(10.1.0.1)
    participant NFT as nftables
    participant IMDS as AWS IMDS<br/>(169.254.169.254)

    VM1->>GW: GET http://169.254.169.254/latest/meta-data/<br/>src: 10.1.0.2:5678
    GW->>NFT: Prerouting DNAT
    Note over NFT: Rule: ip saddr 10.0.0.0/8<br/>ip daddr 169.254.169.254<br/>DNAT to 169.254.169.254:80
    NFT->>NFT: Postrouting NAT
    Note over NFT: Masquerade<br/>10.1.0.2 → Hypervisor IP<br/>(IMDS only responds to local traffic)
    NFT->>IMDS: src: Hypervisor IP:5678<br/>dst: 169.254.169.254:80
    IMDS-->>NFT: Response with metadata
    NFT-->>NFT: Reverse NAT<br/>Hypervisor IP → 10.1.0.2
    NFT-->>GW: dst: 10.1.0.2:5678
    GW-->>VM1: Metadata delivered
```

### Flow 3: Remote Access via Tailscale

```mermaid
sequenceDiagram
    participant Laptop as Your Laptop<br/>(100.y.y.y)
    participant TS as tailscale0<br/>(100.x.x.x)
    participant NFT as nftables
    participant GW as br-vm1<br/>(10.1.0.1)
    participant VM1 as VM1<br/>(10.1.0.2)

    Note over Laptop,VM1: SSH to VM1 via Tailscale subnet route
    Laptop->>TS: SSH to 10.1.0.2:22<br/>src: 100.y.y.y
    TS->>NFT: Forward chain check
    Note over NFT: Rule: iifname tailscale0<br/>oifname br-vm1<br/>ACCEPT ✅
    NFT->>GW: Forward to VM1
    GW->>VM1: SSH connection
    VM1-->>GW: SSH response
    GW-->>NFT: Return traffic
    Note over NFT: Connection tracking:<br/>established connection ✅
    NFT-->>TS: Forward response
    TS-->>Laptop: SSH session established
```

### Flow 4: VM1 to VM2 (BLOCKED - Isolation)

```mermaid
sequenceDiagram
    participant VM1 as VM1<br/>(10.1.0.2)
    participant GW1 as br-vm1<br/>(10.1.0.1)
    participant NFT as nftables
    participant GW2 as br-vm2<br/>(10.2.0.1)
    participant VM2 as VM2<br/>(10.2.0.2)

    VM1->>GW1: Ping 10.2.0.2<br/>src: 10.1.0.2
    GW1->>NFT: Forward chain check
    Note over NFT: Rule: iifname br-vm1<br/>oifname br-vm2<br/>DROP ❌
    NFT->>NFT: Log: "FORWARD DROP"
    NFT--xGW2: Packet dropped
    Note over VM1: Connection timeout<br/>(no response)
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
        FWD_ISOLATE{Inter-VM?<br/>br-vmX → br-vmY}
        FWD_TS_VM{Tailscale<br/>→ VM?}
        FWD_VM_WAN{VM → Internet?}
        FWD_WAN_VM{Internet → VM?}
        FWD_LOG[Log & Drop]
        FWD_ACCEPT[ACCEPT]
        FWD_DROP[DROP]
    end

    subgraph NAT_Pre["PREROUTING (NAT)"]
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

    PKT --> PRE_IMDS
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
```

---

## Isolation Mechanism

### How VM Isolation Works

The `generateIsolationRules` function creates a rule matrix:

```
Source → Target      br-vm1  br-vm2  br-vm3  br-vm4  br-vm5
─────────────────────────────────────────────────────────────
br-vm1                 -      DROP    DROP    DROP    DROP
br-vm2               DROP      -      DROP    DROP    DROP
br-vm3               DROP    DROP      -      DROP    DROP
br-vm4               DROP    DROP    DROP      -      DROP
br-vm5               DROP    DROP    DROP    DROP      -
```

**Generated nftables rules:**
```nft
iifname "br-vm1" oifname "br-vm2" drop
iifname "br-vm1" oifname "br-vm3" drop
iifname "br-vm1" oifname "br-vm4" drop
iifname "br-vm1" oifname "br-vm5" drop
iifname "br-vm2" oifname "br-vm1" drop
iifname "br-vm2" oifname "br-vm3" drop
# ... (continues for all combinations)
```

**Result:** VMs cannot communicate with each other at Layer 2 or Layer 3. All inter-VM traffic is dropped at the hypervisor's forward chain.

### Isolation Benefits

```mermaid
graph LR
    subgraph VM1_Net["VM1 Network (10.1.0.0/24)"]
        VM1["VM1<br/>10.1.0.2"]
    end

    subgraph VM2_Net["VM2 Network (10.2.0.0/24)"]
        VM2["VM2<br/>10.2.0.2"]
    end

    subgraph VM3_Net["VM3 Network (10.3.0.0/24)"]
        VM3["VM3<br/>10.3.0.2"]
    end

    Hypervisor["Hypervisor<br/>(nftables isolation)"]

    VM1 -.->|"❌ BLOCKED"| Hypervisor
    Hypervisor -.->|"❌ BLOCKED"| VM2
    VM1 -.->|"❌ BLOCKED"| VM3
    VM2 -.->|"❌ BLOCKED"| VM3

    style VM1_Net fill:#ffebee
    style VM2_Net fill:#e8f5e9
    style VM3_Net fill:#e3f2fd
    style Hypervisor fill:#fff3e0
```

**Security Benefits:**
- **Attack Surface Reduction**: Compromised VM cannot pivot to other VMs
- **Traffic Isolation**: Each VM's traffic is completely isolated
- **Independent Policies**: Can apply different security policies per VM
- **Compliance**: Meets multi-tenant isolation requirements

---

## IP Address Allocation

### Address Ranges

| Network | Subnet | Bridge IP | VM IP | Gateway | Broadcast | Usable IPs |
|---------|--------|-----------|-------|---------|-----------|------------|
| VM1 | 10.1.0.0/24 | 10.1.0.1 | 10.1.0.2 | 10.1.0.1 | 10.1.0.255 | 10.1.0.2-254 |
| VM2 | 10.2.0.0/24 | 10.2.0.1 | 10.2.0.2 | 10.2.0.1 | 10.2.0.255 | 10.2.0.2-254 |
| VM3 | 10.3.0.0/24 | 10.3.0.1 | 10.3.0.2 | 10.3.0.1 | 10.3.0.255 | 10.3.0.2-254 |
| VM4 | 10.4.0.0/24 | 10.4.0.1 | 10.4.0.2 | 10.4.0.1 | 10.4.0.255 | 10.4.0.2-254 |
| VM5 | 10.5.0.0/24 | 10.5.0.1 | 10.5.0.2 | 10.5.0.1 | 10.5.0.255 | 10.5.0.2-254 |

### Reserved Addresses

- **10.0.0.0/8**: Entire private range used for VMs
- **169.254.169.254**: AWS Instance Metadata Service (IMDS)
- **100.x.x.x/8**: Tailscale CGNAT range (VPN)

### Static IP Configuration

VMs use static IP configuration (no DHCP):

**In VM (systemd-networkd config):**
```nix
systemd.network.networks."10-lan" = {
  matchConfig.Type = "ether";
  address = [ "10.1.0.2/24" ];
  gateway = [ "10.1.0.1" ];
  dns = [ "1.1.1.1" "8.8.8.8" ];
};
```

**Benefits:**
- Predictable IP addresses
- No DHCP server needed
- Faster boot times
- Simplified troubleshooting

---

## Traffic Flow Examples

### Example 1: VM1 Downloads Package from Internet

```mermaid
sequenceDiagram
    autonumber
    participant VM1 as VM1<br/>(10.1.0.2)
    participant BR1 as br-vm1<br/>(10.1.0.1)
    participant NFT as nftables
    participant WAN as enP2p4s0
    participant Server as archive.ubuntu.com

    Note over VM1: curl http://archive.ubuntu.com/package.deb
    VM1->>BR1: TCP SYN<br/>src: 10.1.0.2:4567<br/>dst: archive.ubuntu.com:80
    BR1->>NFT: Forward chain: iifname br-vm1
    NFT->>NFT: Check isolation rules (pass)
    NFT->>NFT: Check VM→WAN rule (ACCEPT)
    NFT->>NFT: Postrouting: Masquerade<br/>10.1.0.2 → Public IP
    NFT->>WAN: src: Public IP:4567<br/>dst: archive.ubuntu.com:80
    WAN->>Server: HTTP GET /package.deb
    Server-->>WAN: HTTP 200 OK + package data
    WAN-->>NFT: dst: Public IP:4567
    NFT-->>NFT: Connection tracking: match<br/>Reverse NAT: Public IP → 10.1.0.2
    NFT-->>BR1: dst: 10.1.0.2:4567
    BR1-->>VM1: Package downloaded ✅
```

### Example 2: SSH from Laptop to VM3 via Tailscale

```mermaid
sequenceDiagram
    autonumber
    participant Laptop as Laptop<br/>(100.50.50.50)
    participant TS as Tailscale Network
    participant HV_TS as tailscale0<br/>(100.100.100.100)
    participant NFT as nftables
    participant BR3 as br-vm3<br/>(10.3.0.1)
    participant VM3 as VM3<br/>(10.3.0.2)

    Note over Laptop: ssh 10.3.0.2
    Laptop->>TS: Encrypted WireGuard tunnel
    TS->>HV_TS: Route via subnet routes
    HV_TS->>NFT: Forward chain: iifname tailscale0<br/>oifname br-vm3
    NFT->>NFT: Check tailscale→VM rule (ACCEPT)
    NFT->>BR3: Forward to 10.3.0.2:22
    BR3->>VM3: SSH handshake
    VM3-->>BR3: SSH response
    BR3-->>NFT: Connection tracking: established
    NFT-->>HV_TS: Return traffic
    HV_TS-->>TS: WireGuard tunnel
    TS-->>Laptop: SSH session established ✅
```

### Example 3: VM2 Tries to Access VM4 (Blocked)

```mermaid
sequenceDiagram
    autonumber
    participant VM2 as VM2<br/>(10.2.0.2)
    participant BR2 as br-vm2<br/>(10.2.0.1)
    participant NFT as nftables
    participant BR4 as br-vm4<br/>(10.4.0.1)
    participant VM4 as VM4<br/>(10.4.0.2)

    Note over VM2: ping 10.4.0.2
    VM2->>BR2: ICMP Echo Request<br/>src: 10.2.0.2<br/>dst: 10.4.0.2
    BR2->>NFT: Forward chain: iifname br-vm2<br/>oifname br-vm4
    NFT->>NFT: Match isolation rule:<br/>iifname "br-vm2" oifname "br-vm4" drop
    NFT->>NFT: Log: "FORWARD DROP: br-vm2→br-vm4"
    Note over NFT: Packet dropped ❌
    Note over VM2: ping timeout<br/>(no response received)
```

### Example 4: VM5 Accesses AWS IMDS

```mermaid
sequenceDiagram
    autonumber
    participant VM5 as VM5<br/>(10.5.0.2)
    participant BR5 as br-vm5<br/>(10.5.0.1)
    participant NFT_PRE as nftables<br/>(Prerouting)
    participant NFT_POST as nftables<br/>(Postrouting)
    participant IMDS as AWS IMDS<br/>(169.254.169.254)

    Note over VM5: curl http://169.254.169.254/latest/meta-data/instance-id
    VM5->>BR5: HTTP GET<br/>src: 10.5.0.2:8888<br/>dst: 169.254.169.254:80
    BR5->>NFT_PRE: Prerouting chain
    NFT_PRE->>NFT_PRE: Match: ip saddr 10.0.0.0/8<br/>ip daddr 169.254.169.254
    NFT_PRE->>NFT_PRE: DNAT: keep dst as 169.254.169.254
    NFT_PRE->>NFT_POST: Postrouting chain
    NFT_POST->>NFT_POST: Masquerade:<br/>10.5.0.2 → Hypervisor local IP<br/>(IMDS only responds to local requests)
    NFT_POST->>IMDS: src: Hypervisor IP<br/>dst: 169.254.169.254:80
    IMDS-->>NFT_POST: Instance ID response
    NFT_POST-->>NFT_POST: Reverse NAT:<br/>Hypervisor IP → 10.5.0.2
    NFT_POST-->>BR5: dst: 10.5.0.2:8888
    BR5-->>VM5: Instance metadata ✅
```

---

## Key Takeaways

### Architecture Principles

1. **Defense in Depth**: Multiple layers of isolation (bridges, nftables, connection tracking)
2. **Least Privilege**: Default deny policies with explicit allow rules
3. **Network Segmentation**: Each VM in its own /24 subnet
4. **Stateful Inspection**: Connection tracking for return traffic
5. **Atomic Configuration**: All nftables rules update together (no partial states)

### Operational Notes

**Adding a new VM:**
1. Add network definition to `modules/networks.nix`
2. Configuration automatically generates bridge, TAP, isolation rules
3. No manual firewall rule updates needed

**Troubleshooting network issues:**
```bash
# View nftables ruleset
nft list ruleset

# Monitor traffic on bridge
tcpdump -i br-vm1 -n

# Check NAT translations
nft list table ip nat

# View dropped packets
journalctl -k | grep "FORWARD DROP"

# Test connectivity from VM
ssh 10.1.0.2 "ping -c 3 8.8.8.8"
```

**Performance Considerations:**
- TAP interfaces: ~10-40 Gbps throughput
- nftables: Negligible overhead (<1% CPU)
- Connection tracking: Handles 100k+ concurrent connections
- Bridge forwarding: Wire-speed within hypervisor

---

## References

- **nftables wiki**: https://wiki.nftables.org/
- **systemd-networkd**: https://www.freedesktop.org/software/systemd/man/systemd.network.html
- **Linux bridge**: https://wiki.linuxfoundation.org/networking/bridge
- **Tailscale subnet routes**: https://tailscale.com/kb/1019/subnets/
- **AWS IMDS**: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
