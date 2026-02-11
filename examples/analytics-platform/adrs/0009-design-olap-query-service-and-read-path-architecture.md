# 9. Design OLAP Query Service and Read Path Architecture

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Design the Query API service — the read-path component that sits between the Analytics UI and the ClickHouse/Redis backend — including tenant-aware query routing, connection pooling, concurrency control, and read-replica strategy to guarantee ≤1.5s P95 latency at 900–1,318 peak RPS without impacting write-path performance.
- **Business drivers:** The Analytics UI serves 100,000–146,410 analysts/marketers (Years 1–5) querying dashboards with arbitrary multi-dimensional filters. The read path must isolate query workloads from the write-heavy ingestion pipeline to prevent mutual degradation. Tenant fairness must prevent a single high-volume tenant from starving others.
- **Relevant QAs (IDs):**
  - P-1 — Performance (Query Latency): ≤1.5s P95 for multi-dimensional segmentation over ≤3 months
  - A-2 — Availability (System Uptime): 99.9% uptime; read path must survive partial ClickHouse node failures
- **Relevant Risks:**
  - RISK-QUERY-01 — Query latency exceeds 1.5s SLA during peak read load (900–1,318 RPS) if queries compete with writes on same nodes
  - RISK-QUERY-02 — Complex multi-dimensional queries (geo, source, device, UTM) over 3 months cause full scans and resource exhaustion
- **Depends on:** ADR-0006 (ClickHouse cluster), ADR-0007 (hot tier on NVMe SSD), ADR-0008 (materialized views + Redis cache)

### Read Path Performance Budget

| Component | Latency Budget | Notes |
|---|---|---|
| Network (client ↔ Query API) | ~50 ms | Regional API endpoints |
| Redis cache lookup | ~5 ms (hit) | Cache-aside per ADR-0008 |
| Query API processing | ~20 ms | Parsing, routing, serialization |
| ClickHouse query execution | ~500–1,200 ms (MV), ~1,000–1,400 ms (raw) | Hot tier, partition-pruned |
| Redis cache write-back | ~5 ms (async) | Non-blocking |
| **Total (cache hit)** | **~75 ms** | Well within 1.5s |
| **Total (cache miss, MV query)** | **~575–1,275 ms** | Within 1.5s P95 |
| **Total (cache miss, raw query)** | **~1,075–1,475 ms** | Borderline; needs monitoring |

## Decision

### Compare Read Path Architectures

| Criterion | A: Direct ClickHouse Access (UI → ClickHouse) | B: Stateless Query API Gateway (UI → API → ClickHouse) | C: Query API with Read Replicas + Write/Read Separation |
|---|---|---|---|
| **Read/Write Isolation** | 🟥 Queries and writes compete for same ClickHouse resources; write merges impact query latency | 🟨 API can route queries but still hits same ClickHouse nodes as writers | 🌟 Dedicated read replicas serve queries; write nodes handle ingestion exclusively |
| **Query Latency Predictability** | 🟥 Unpredictable under heavy write load; merge operations cause latency spikes | 🟨 API provides timeout/retry but doesn't solve resource contention | 🌟 Read replicas insulated from write merges; predictable P95 latency |
| **Tenant Fairness** | 🟥 No tenant-level query governance; one tenant can exhaust cluster resources | 🟩 API enforces per-tenant rate limits, query quotas, and timeout policies | 🌟 API rate limits + dedicated read capacity prevents cross-tenant interference |
| **Availability During Write Bursts** | 🟥 Write peaks degrade read performance; no isolation | 🟨 API can circuit-break but read quality degrades | 🟩 Read replicas maintain query SLA independent of write burst activity |
| **Horizontal Read Scaling** | 🟨 Add ClickHouse nodes (both read+write) | 🟨 API scales but backend is shared | 🌟 Scale read replicas independently based on query RPS |
| **Operational Complexity** | 🟩 Simplest; no additional services | 🟨 Stateless API service + deployment | 🟨 Read replica management + API service; replica lag monitoring needed |
| **Cost** | 🟩 No additional infrastructure | 🟩 Lightweight API service | 🟨 Additional ClickHouse read replica nodes; justified by SLA requirements |

### Evaluation Summary

- **Option A** is eliminated — direct client access to ClickHouse provides no read/write isolation, no tenant governance, and no protection against write-induced latency spikes.
- **Option B** adds governance and routing but doesn't solve the core problem: queries and writes competing for the same ClickHouse resources during peak ingestion periods.
- **Option C** provides full read/write isolation via dedicated read replicas, enabling predictable P95 latency independent of write load, alongside tenant-level query governance.

### Decision

Adopt **Option C: Query API Service with Dedicated ClickHouse Read Replicas and Write/Read Separation**.

#### 1. ClickHouse Read/Write Topology

| Role | Nodes | Responsibilities | Data Source |
|---|---|---|---|
| **Write nodes** | Primary shard replicas (per ADR-0006) | Kafka consumption, async inserts, MergeTree merges, MV population | Kafka `events.ingest` topic |
| **Read replicas** | 2+ replicas per shard (separate instances) | Serve all analytical queries from Query API | Asynchronous replication from write nodes via `ReplicatedMergeTree` |

- Read replicas are configured with `readonly=1` to prevent accidental writes.
- Replica lag target: <60 seconds (acceptable given A-1's 50–100 minute freshness tolerance).
- Read replicas provisioned on NVMe SSD for hot-tier data; same tiered storage config as write nodes (ADR-0007).

#### 2. Query API Service Design

| Design Element | Decision | Rationale |
|---|---|---|
| **Architecture** | Stateless HTTP/gRPC service; horizontal auto-scaling | Stateless for easy scaling; no session affinity required |
| **Scaling** | Auto-scale on CPU (target 60%) and request rate (target: 80% of rated RPS) | Absorbs peak 1,318 RPS with headroom |
| **Connection pooling** | Connection pool per ClickHouse read replica; max 50 connections per node | Prevents connection exhaustion; distributes load |
| **Load balancing** | Round-robin across healthy read replicas with health checks (query-based liveness) | Even distribution; unhealthy nodes removed within 10s |
| **Query timeout** | 5 seconds hard timeout per query | Prevents runaway queries from exhausting connections (RISK-QUERY-02) |
| **Retry policy** | 1 retry on timeout/connection error to a different replica; no retry on query error | Masks transient failures; prevents retry storms |

#### 3. Tenant-Aware Query Governance

| Mechanism | Configuration | Purpose |
|---|---|---|
| **Per-tenant rate limiter** | Token bucket: 50 queries/min default; configurable per plan tier | Prevents noisy-neighbor query flood (RISK-QUERY-01) |
| **Per-tenant concurrency limit** | Max 10 concurrent ClickHouse queries per tenant | Prevents single tenant monopolizing connection pool |
| **Query complexity scoring** | Reject queries exceeding complexity threshold (estimated scan rows > 10B, time range > 3 months) | Protects cluster from unbounded scans (RISK-QUERY-02) |
| **Priority queues** | 2 tiers: interactive (dashboard) = high priority; export/batch = low priority | Dashboard queries get resource priority over bulk exports |
| **HTTP 429 response** | Returned when tenant exceeds rate/concurrency limits | Standard backpressure signal to client |

#### 4. Query Routing (Integrated with ADR-0008)

```
Analytics UI → Query API Service
  ├── Authentication + tenant extraction
  ├── Rate limit / concurrency check
  │     └── Exceeded → HTTP 429
  ├── Redis cache lookup (ADR-0008)
  │     └── HIT → return (<10 ms)
  ├── Query classifier
  │     ├── Dashboard pattern → route to MV table on read replica
  │     └── Ad-hoc / complex → route to raw events table on read replica
  ├── Execute on ClickHouse read replica (connection pool, 5s timeout)
  ├── Write result to Redis (async, with TTL)
  └── Return result to client
```

#### 5. Availability and Failure Handling

| Failure Scenario | Behavior | Impact |
|---|---|---|
| Read replica node failure | Load balancer removes node; traffic redistributed to remaining replicas | Brief latency spike; no outage (A-2) |
| All read replicas unavailable | Circuit breaker opens; Query API returns HTTP 503 with retry-after header | Read path unavailable; write path unaffected |
| Redis unavailable | Cache bypass (ADR-0008); all queries fall through to ClickHouse read replicas | Higher ClickHouse load; latency increases but within budget |
| Query API pod failure | Kubernetes restarts pod; load balancer reroutes | Sub-second failover; no client-visible impact |
| ClickHouse replica lag > 5 min | Alert fires; replica marked degraded but still serves queries (stale data acceptable per A-1) | Data freshness degrades; no latency impact |

Supersedes: none.

## Consequences

- ✅ Dedicated read replicas eliminate write-induced latency spikes, ensuring predictable ≤1.5s P95 even during 5M peak write RPS on write nodes (P-1, RISK-QUERY-01).
- ✅ Independent read-replica scaling allows adding query capacity without affecting ingestion pipeline (P-1, A-2).
- ✅ Per-tenant rate limiting and concurrency caps prevent noisy-neighbor degradation across 100K+ tenants (RISK-QUERY-01).
- ✅ Query complexity scoring blocks unbounded scans before they reach ClickHouse, protecting cluster stability (RISK-QUERY-02).
- ✅ Stateless Query API with auto-scaling absorbs peak 1,318 RPS with horizontal elasticity (A-2).
- ✅ Layered failure handling (replica failover, cache bypass, circuit breakers) maintains 99.9% read-path availability (A-2).
- ⚠️ Read replicas add ClickHouse infrastructure cost (~2 additional replica nodes per shard); justified by P-1 SLA requirements.
- ⚠️ Replica lag (target <60s) means read replicas serve slightly stale data — acceptable within A-1's 50–100 minute freshness window but must be monitored.
- ⚠️ Query complexity scoring heuristics may reject valid queries; requires tuning and an override mechanism for admin users.
- ⚠️ Two-tier priority queue adds routing logic complexity; must be tested under load to validate fairness behavior.
- **Follow-ups:** ADR-0010 (Event Processing Pipeline) will define the batch/stream processing that feeds MVs. ADR-0012 (Observability) will define query-latency SLO dashboards, cache hit-rate alerts, and replica-lag monitoring.
