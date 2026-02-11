# 5. Design Ingestion Pipeline Architecture and Partitioning Strategy

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Define the ingestion pipeline architecture—from SDK event emission to Kafka topic persistence—including partitioning strategy, consumer group design, backpressure management, and multi-stage buffering.
- **Business drivers:** The platform must reliably ingest 100B–146B events/day from geographically distributed tenant websites, sustain 5M peak write RPS during traffic bursts, and guarantee zero event loss for acknowledged writes. The architecture must scale linearly with traffic growth (+10% YoY) without service degradation.
- **Relevant QAs (IDs):**
  - P-2 — Write Throughput: sustain 1.16M–1.69M avg RPS, 3.47M–5.08M peak RPS
  - S-1 — Horizontal Scalability: handle 100B→146B events/day over 5 years
  - D-1 — Durability: zero data loss for acknowledged events
  - A-2 — Availability: 99.9% uptime during business hours
- **Relevant Risks:**
  - RISK-INGEST-01 — Write throughput at mind-blowing tier requires extreme horizontal partitioning
  - RISK-INGEST-02 — Peak traffic bursts (3× multiplier) cause event loss or backpressure failures
  - RISK-SCALE-01 — Autoscaling lag during spikes causes temporary capacity shortfall
  - RISK-DATA-01 — Data loss during node failures or deployment updates
- **Depends on:** ADR-0004 (Apache Kafka selected as message queue)

### Pipeline Throughput Requirements

| Parameter | Year 1 | Year 5 | Source |
|---|---|---|---|
| Average Write RPS | 1,157,407 | 1,694,560 | ADR-0003 |
| Peak Write RPS (3×) | 3,472,222 | 5,083,681 | ADR-0003 |
| Write Bandwidth (avg) | 0.54 GB/s | 0.79 GB/s | ADR-0003 |
| Write Bandwidth (peak) | 1.62 GB/s | 2.37 GB/s | ADR-0003 |
| Event Size | ~0.5 KB | ~0.5 KB | ADR-0002 |

## Decision

### Compare Ingestion Pipeline Topologies

| Criterion | A: Single-Tier (SDK → API Gateway → Kafka) | B: Two-Tier (SDK → Edge Collectors → Kafka) | C: Three-Tier (SDK → Edge CDN → Regional Collectors → Central Kafka) |
|---|---|---|---|
| **Latency (SDK to Kafka)** | 🟩 Lowest hop count | 🟩 Low; edge collectors near clients | 🟨 Additional hop adds 10–50 ms |
| **Throughput Scalability** | 🟨 API Gateway becomes bottleneck at 5M RPS | 🟩 Edge collectors distribute load across regions | 🌟 CDN absorbs burst; collectors batch and forward |
| **Peak Burst Absorption** | 🟥 No buffering before Kafka; backpressure propagates to clients | 🟩 Collectors buffer locally during bursts | 🌟 CDN + collectors provide two buffering stages |
| **Fault Isolation** | 🟥 Single failure domain; gateway outage = total ingestion loss | 🟩 Regional isolation; one region's failure doesn't affect others | 🌟 CDN provides first line of defense; regional failures are isolated |
| **Operational Complexity** | 🟩 Fewest components to manage | 🟨 Regional collector fleet requires orchestration | 🟥 CDN config + regional collectors + central Kafka coordination |
| **Cost Efficiency** | 🟩 Lowest infrastructure cost | 🟨 Moderate; regional collector compute costs | 🟨 CDN costs + regional compute; offset by reduced Kafka peak sizing |
| **Durability During Failures** | 🟥 Events lost if gateway/Kafka unavailable | 🟩 Local disk buffer on collectors survives short outages | 🟩 CDN retry + collector disk buffer |
| **Geographic Distribution** | 🟥 Centralized; high latency for distant clients | 🟩 Collectors deployed per-region reduce client latency | 🌟 CDN endpoints globally; minimal client latency |

### Evaluation Summary

- **Option A** is eliminated at the target scale: a centralized API Gateway cannot absorb 5M peak RPS without becoming a bottleneck, and offers no buffering layer before Kafka.
- **Option C** provides the strongest burst absorption and fault isolation, but introduces CDN-layer complexity that is premature before validating edge collector behavior under load.
- **Option B** balances throughput distribution, fault isolation, and operational complexity. Edge collectors provide regional load distribution, local disk buffering for burst absorption, and a natural unit of horizontal scaling.

### Decision

Adopt **Topology B: Two-Tier Ingestion (SDK → Regional Edge Collectors → Central Kafka Cluster)** with the following design:

#### 1. Edge Collector Layer

- Deploy stateless collector services in each target region (initial: 3 regions; expand with traffic growth).
- Collectors accept events via HTTPS, validate schema, assign server-side timestamps, and batch events before producing to Kafka.
- Local disk-backed buffer (Write-Ahead Log) absorbs bursts when Kafka is temporarily unreachable (retention: 1 hour).
- Horizontal scaling: auto-scale collector instances based on CPU and inbound RPS metrics with 15% warm standby headroom (RISK-SCALE-01 mitigation).

#### 2. Kafka Topic and Partitioning Strategy

| Design Element | Decision | Rationale |
|---|---|---|
| **Primary topic** | `events.ingest` | Single logical topic for all raw events |
| **Partition key** | `tenant_id` | Ensures per-tenant ordering; distributes load across tenants |
| **Initial partition count** | 1,024 partitions | Supports ~5,000 RPS per partition at peak (5M / 1,024 ≈ 4,970); allows parallel consumer processing |
| **Partition growth** | Add partitions as throughput scales (no partition reduction) | Kafka supports online partition expansion |
| **Replication factor** | 3 (across AZs) | Zero data loss with `min.insync.replicas=2` (D-1) |
| **Producer config** | `acks=all`, `enable.idempotence=true`, `max.in.flight.requests=5` | Durability + exactly-once semantics at producer level |
| **Retention** | 72 hours (3 days) | Buffer for consumer lag, reprocessing, and incident recovery |
| **Compression** | LZ4 (producer-side) | Reduces network bandwidth by ~60% with minimal CPU overhead |

#### 3. Dead-Letter Queue (DLQ)

- Topic: `events.dlq` — receives events that fail schema validation or exceed retry limits (3 retries with exponential backoff).
- Monitored with alerting on DLQ depth > 10,000 messages (RISK-INGEST-02).
- Manual or automated reprocessing workflow from DLQ back to `events.ingest`.

#### 4. Backpressure and Rate Limiting

| Mechanism | Scope | Behavior |
|---|---|---|
| **Per-tenant rate limiting** | Edge collectors | Token-bucket rate limiter; excess events queued locally or rejected with 429 status |
| **Producer buffering** | Collector → Kafka | `buffer.memory=256MB`, `linger.ms=10` for micro-batching |
| **Circuit breaker** | Collector → Kafka | Open circuit if Kafka produce latency > 5s; buffer to local WAL; retry after 30s |
| **Consumer lag alerting** | Kafka consumers | Alert if consumer group lag exceeds 5 minutes of event volume |

#### 5. Autoscaling Strategy

- Edge collectors scale on inbound RPS (target: 70% of rated capacity per instance).
- Kafka brokers provisioned for peak capacity with 20% headroom; scaling events planned (not reactive) based on traffic forecasts.
- Predictive scaling triggers pre-warming 30 minutes before historically known peak periods (RISK-SCALE-01).

Supersedes: none.

## Consequences

- ✅ Regional edge collectors distribute 5M peak RPS across multiple regions, eliminating single-point bottleneck (P-2, RISK-INGEST-01).
- ✅ Local WAL buffer on collectors absorbs burst traffic during transient Kafka unavailability (D-1, RISK-INGEST-02).
- ✅ 1,024 partitions with `tenant_id` key provide linear consumer parallelism and per-tenant ordering (S-1).
- ✅ `acks=all` + RF=3 + idempotent producers ensure zero data loss for acknowledged events (D-1, RISK-DATA-01).
- ✅ DLQ with monitoring and reprocessing prevents silent event loss on processing failures (RISK-INGEST-02).
- ✅ Warm standby + predictive scaling mitigates autoscaling lag during traffic spikes (RISK-SCALE-01).
- ⚠️ `tenant_id` partitioning may cause hot partitions if a single tenant generates disproportionate traffic; sub-partitioning (e.g., `tenant_id + shard_key`) may be needed for top-tier tenants.
- ⚠️ 1,024 partitions create non-trivial metadata overhead; partition count must be monitored and expanded conservatively.
- ⚠️ Multi-region collector deployment requires cross-region Kafka replication or regional Kafka clusters with aggregation (to be resolved in Iteration 4, ADR-0011).
- **Follow-ups:** ADR-0006 (Distributed Database Technology Selection) will define the storage layer consuming from `events.ingest`. ADR-0011 (HA Architecture) will address multi-region Kafka topology.
