# 11. Design High Availability and Multi-AZ Deployment Architecture

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Define the multi-AZ deployment architecture that delivers 99.9% uptime (≤43 minutes downtime/month) during business hours across all platform components — Kafka, ClickHouse, Redis, Query API, and Edge Collectors — including automatic failover, network bandwidth distribution, and zero-downtime deployment strategy.
- **Business drivers:** The platform serves 100,000–146,410 analysts/marketers who depend on continuous dashboard availability during business hours (9am–9pm local time across all regions). Downtime directly impacts customer trust and SLA compliance. Network bandwidth approaching 11.2 Gbps by Year 5 requires geographic distribution to avoid single-AZ saturation.
- **Relevant QAs (IDs):**
  - A-2 — Availability (System Uptime): 99.9% uptime during business hours (≤43 min downtime/month); automatic failover on node crashes, network partitions, deployment updates
  - D-1 — Durability: zero data loss during node failures via multi-AZ replication
  - S-1 — Scalability (Horizontal): network bandwidth distribution across AZs and regions
- **Relevant Risks:**
  - RISK-DATA-01 — Data loss during node failures or deployment updates (Low likelihood, 🟥 High impact)
  - RISK-NETWORK-01 — Network bandwidth escalates to 1.40 GB/s (11.2 Gbps) by Year 5, approaching 40 Gbps threshold per AZ
  - RISK-OPS-01 — Managing 1M+ RPS distributed system requires senior-level expertise; multi-AZ adds operational complexity
- **Depends on:** ADR-0004 (Kafka KRaft, RF=3), ADR-0005 (Edge Collectors, 3 regions), ADR-0006 (ClickHouse ReplicatedMergeTree, RF=2/shard), ADR-0008 (Redis Cluster, 6 nodes), ADR-0009 (Query API, read replicas)

### Availability Budget

| Component | Allowed Downtime/Month | Implication |
|---|---|---|
| Overall platform | ≤43 minutes | 99.9% uptime |
| Individual component | ≤15 minutes (RTO target) | Must fail over faster than budget share |
| Planned maintenance | Excluded from SLA | Zero-downtime deployments required regardless |

## Decision

### Compare Multi-AZ Deployment Topologies

| Criterion | A: Single-AZ (All Components) | B: Multi-AZ Active-Passive | C: Multi-AZ Active-Active (All AZs Serve Traffic) |
|---|---|---|---|
| **Availability (99.9%)** | 🟥 Single AZ failure = complete outage; cannot meet 99.9% | 🟩 Passive AZ ready for failover; brief interruption during switchover | 🌟 All AZs serve traffic; AZ failure degrades capacity but no outage |
| **Failover Time (RTO)** | N/A (no failover) | 🟨 1–5 minutes for DNS/LB failover | 🌟 Instant; LB redistributes to surviving AZs |
| **Data Durability During AZ Loss** | 🟥 Potential data loss if AZ destroyed | 🟩 Replicated to passive AZ; RPO near zero | 🌟 Data replicated across all AZs; RPO = 0 for acknowledged writes |
| **Network Bandwidth Distribution** | 🟥 All traffic in single AZ; 11.2 Gbps concentrated | 🟨 Primary AZ handles all traffic; passive idle | 🌟 Traffic distributed across AZs; ~3.7 Gbps per AZ (3 AZs) |
| **Resource Utilization** | 🟩 No idle capacity | 🟥 Passive AZ resources idle (50% waste) | 🟩 All AZ resources active; no idle waste |
| **Operational Complexity** | 🟩 Simplest | 🟨 Failover orchestration; passive AZ drift monitoring | 🟨 Cross-AZ coordination; consistency monitoring |
| **Cost** | 🟩 Lowest | 🟨 ~2× compute for passive standby | 🟩 Higher than single-AZ but no idle waste |
| **Zero-Downtime Deployments** | 🟨 Rolling within AZ | 🟩 Deploy to passive first, then switchover | 🌟 Rolling across AZs; canary per AZ |

### Evaluation Summary

- **Option A** is eliminated — cannot meet 99.9% SLA; single AZ failure is unacceptable.
- **Option B** wastes 50% of compute on idle standby and introduces failover lag (1–5 min) that consumes the availability budget.
- **Option C** distributes traffic across all AZs, provides instant failover via load balancer redistribution, distributes network bandwidth evenly, and eliminates idle capacity waste.

### Decision

Adopt **Multi-AZ Active-Active Deployment** across 3 Availability Zones with the following per-component design:

#### Per-Component HA Configuration

| Component | AZ Distribution | Replication/Redundancy | Failover Mechanism | RTO |
|---|---|---|---|---|
| **Kafka (KRaft)** | 3 brokers per AZ (9 total); KRaft controllers: 1 per AZ (3 total) | RF=3 across AZs; `min.insync.replicas=2` (ADR-0004) | KRaft leader election (<30s); producers reconnect to new leader | <30 seconds |
| **ClickHouse (write)** | 1 shard replica per AZ (2 replicas/shard across 2 AZs; 3rd AZ for Keeper) | ReplicatedMergeTree RF=2; ClickHouse Keeper: 3-node ensemble (1/AZ) | Keeper elects new leader; write traffic rerouted via LB | <60 seconds |
| **ClickHouse (read)** | Read replicas in all 3 AZs (ADR-0009) | Async replication from write nodes | LB removes unhealthy replica; redistributes queries | <10 seconds |
| **Redis Cluster** | 3 masters + 3 replicas (1 master + 1 replica per AZ) (ADR-0008) | Automatic replica promotion on master failure | Redis Cluster FAILOVER; Sentinel-less via Cluster mode | <15 seconds |
| **Query API** | N instances per AZ (Kubernetes Deployment, min 2 pods/AZ) | Stateless; no replication needed | K8s readiness probe + LB health check | <5 seconds |
| **Edge Collectors** | Deployed per-region (ADR-0005); each region spans ≥2 AZs | Stateless + local WAL buffer | LB removes unhealthy collector; WAL prevents data loss | <5 seconds |
| **Backfill Consumer** | K8s Deployment, 1+ pods per AZ | Stateless; Kafka consumer group rebalance | Consumer group rebalance on pod failure | <30 seconds |

#### Network Bandwidth Distribution

| Metric | Single-AZ | 3-AZ Active-Active | Headroom (40 Gbps threshold) |
|---|---|---|---|
| Year 1 total bandwidth | 7.7 Gbps concentrated | ~2.6 Gbps per AZ | 🟩 93% headroom |
| Year 5 total bandwidth | 11.2 Gbps concentrated | ~3.7 Gbps per AZ | 🟩 91% headroom |
| Cross-AZ replication overhead | 0 | ~30% additional (Kafka RF=3, CH RF=2) | Accounted in per-AZ budget |

#### Zero-Downtime Deployment Strategy

| Strategy | Component | Process |
|---|---|---|
| **Rolling update** | Query API, Edge Collectors, Backfill Consumer | K8s rolling deployment: maxSurge=1, maxUnavailable=0; one AZ at a time |
| **Canary per AZ** | ClickHouse, Kafka | Deploy to one AZ first; validate metrics for 15 min; proceed to remaining AZs |
| **Blue-green (schema changes)** | ClickHouse (DDL) | Create new table version; migrate Kafka Engine to new table; drop old after validation |
| **Rolling restart** | Redis Cluster | Restart replicas first, then masters one-by-one with automatic failover |

#### Failure Scenarios and Recovery

| Scenario | Impact | Recovery | Data Loss |
|---|---|---|---|
| Single AZ failure | ~33% capacity reduction; traffic redistributed | Automatic via LB; no manual intervention | Zero (replicated) |
| Kafka broker failure | Partition leaders re-elected on surviving brokers | KRaft leader election (<30s) | Zero (ISR, acks=all) |
| ClickHouse write node failure | Write traffic rerouted to replica in other AZ | Keeper-triggered replica promotion | Zero (ReplicatedMergeTree) |
| Redis master failure | Reads/writes rerouted to new master (promoted replica) | Cluster FAILOVER (<15s) | Near-zero (async replication; <1s window) |
| Full region failure (all 3 AZs) | Complete outage; beyond 99.9% SLA scope | Manual failover to DR region (future ADR) | Zero for Kafka (72h retention); minimal for Redis |

Supersedes: none.

## Consequences

- ✅ Active-active across 3 AZs provides instant failover with no traffic interruption — single AZ failure degrades capacity by ~33% but maintains service (A-2).
- ✅ Combined RTO <60 seconds for any single-component failure, well within the 43 min/month availability budget (A-2).
- ✅ Network bandwidth distributed to ~3.7 Gbps per AZ by Year 5, maintaining >90% headroom against 40 Gbps threshold (RISK-NETWORK-01).
- ✅ Kafka RF=3 + ClickHouse RF=2 + Kafka replay (72h) ensure zero data loss for any single-AZ failure (D-1, RISK-DATA-01).
- ✅ Zero-downtime deployment via rolling/canary strategies eliminates planned maintenance downtime (A-2).
- ⚠️ Cross-AZ replication adds ~30% network overhead and inter-AZ data transfer costs; must be budgeted.
- ⚠️ ClickHouse Keeper (3-node ensemble across AZs) is a critical dependency — Keeper loss prevents write quorum; monitoring essential.
- ⚠️ Redis async replication means <1 second of writes may be lost on master failure — acceptable for cache data but must be documented.
- ⚠️ Full-region disaster recovery (multi-region) is out of scope; requires future ADR for cross-region Kafka mirroring and ClickHouse backup restoration.
- **Follow-ups:** ADR-0012 (Observability) will define AZ-level health dashboards, failover alerting, and cross-AZ latency monitoring. Future ADR for multi-region DR if business requires resilience beyond single-region failure.
