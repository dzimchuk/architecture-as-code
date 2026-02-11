# 8. Design Query Optimization and Caching Strategy

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Design the caching layer and query-result optimization strategy to guarantee ≤1.5s P95 query latency for multi-dimensional dashboard segmentation over 3-month periods, under peak read loads of 900–1,318 combined RPS.
- **Business drivers:** Analysts and marketers require interactive dashboard responses across geolocation, traffic source, device, browser, and UTM dimensions. Query latency directly impacts user experience and product adoption. The read path must absorb peak query traffic without degrading write-heavy ingestion performance on the shared ClickHouse cluster.
- **Relevant QAs (IDs):**
  - P-1 — Performance (Query Latency): reports delivered within 1.5s P95 for any parameter combination over ≤3 months
  - A-2 — Availability (System Uptime): 99.9% uptime; cache layer must not become a single point of failure
- **Relevant Risks:**
  - RISK-QUERY-01 — Query latency exceeds 1.5s SLA during peak read load (900–1,318 RPS combined); cache miss rate >40% triggers degradation
  - RISK-QUERY-02 — Complex multi-dimensional queries (geo, source, device, UTM) over 3-month periods degrade ClickHouse scan performance
- **Depends on:** ADR-0006 (ClickHouse selected), ADR-0007 (hot tier on NVMe SSD for <3-month data)

### Read Path Requirements

| Requirement | Value | Source |
|---|---|---|
| Query latency (P95) | ≤1.5 seconds | P-1 |
| Real-time peak read RPS | 450–659 | ADR-0003 |
| Aggregated peak read RPS | 450–659 | ADR-0003 |
| Combined peak read RPS | 900–1,318 | ADR-0003 |
| Query dimensions | Geolocation, traffic source, device, browser, UTM tags | P-1 |
| Query time range | Up to 3 months | P-1 |
| Data freshness tolerance | 50–100 minutes (A-1) | Enables cache TTLs aligned with batch window |
| Hot tier data volume | 3.2–4.7 TB compressed | ADR-0007 |

## Decision

### Compare Caching Strategies

| Criterion | A: No Cache (ClickHouse Only) | B: Query-Result Cache (Redis/Memcached) | C: Pre-Aggregated Materialized Views + Query-Result Cache | D: CDN/Edge Cache for Dashboard API |
|---|---|---|---|---|
| **P95 Latency at Peak RPS** | 🟨 Sub-second for simple queries; >1.5s risk for complex multi-dimensional at peak | 🟩 Cache hits <10 ms; misses fall through to ClickHouse | 🌟 MVs reduce scan volume →sub-second even on miss; cache hits <10 ms | 🟩 Edge hits <50 ms; but high cardinality limits hit rate |
| **Cache Hit Rate (multi-dimensional)** | N/A | 🟨 Low for high-cardinality dimension combinations; many unique query shapes | 🟩 MVs cover common aggregation patterns; result cache handles repeated queries | 🟥 Very low; dimension combinations create unbounded cache key space |
| **ClickHouse Load Reduction** | 🟥 All queries hit ClickHouse; peak RPS directly impacts cluster | 🟩 Repeated queries served from cache; reduces ClickHouse load | 🌟 MVs shift aggregation to write-time; cache absorbs repeated reads | 🟨 Only identical URL-level hits offloaded |
| **Data Freshness** | 🌟 Real-time (latest merged parts) | 🟩 TTL-controlled; configurable staleness | 🟩 MV refresh aligned with batch pipeline; result cache TTL matches | 🟨 TTL at edge; harder to invalidate on data arrival |
| **Operational Complexity** | 🟩 No additional infrastructure | 🟨 Redis/Memcached cluster to manage; eviction policies, HA | 🟨 MVs require DDL management; Redis cluster to manage | 🟩 CDN managed; but cache invalidation logic needed |
| **Storage Overhead** | 🟩 None | 🟩 Minimal (serialized query results) | 🟨 MVs consume additional ClickHouse storage (pre-aggregated tables) | 🟩 Minimal |
| **Multi-Tenancy Isolation** | 🟩 ClickHouse handles via query filtering | 🟩 Cache key includes tenant_id; natural isolation | 🟩 MVs partitioned by tenant; cache keyed by tenant | 🟩 API-level tenant routing |

### Evaluation Summary

- **Option A** is insufficient alone — complex multi-dimensional queries over 3-month ranges risk exceeding 1.5s P95 at 900+ peak RPS without any caching or pre-aggregation layer.
- **Option B** provides fast responses for repeated queries but suffers low hit rate for high-cardinality multi-dimensional dashboards where each filter combination is unique.
- **Option D** is ineffective — analytics dashboards have high query cardinality with user-specific filter combinations, making edge caching impractical.
- **Option C** combines the strengths: materialized views shift heavy aggregation to write-time (reducing per-query scan volume), while a query-result cache absorbs repeated identical requests.

### Decision

Adopt **Option C: Pre-Aggregated Materialized Views + Query-Result Cache (Redis Cluster)**.

#### 1. ClickHouse Materialized Views (Pre-Aggregation)

| Materialized View | Aggregation Grain | Source Table | Dimensions | Use Case |
|---|---|---|---|---|
| `mv_hourly_page_views` | Hourly | `events` | `tenant_id`, `event_date`, `hour`, `page_url` | Page-level traffic dashboards |
| `mv_daily_segmentation` | Daily | `events` | `tenant_id`, `event_date`, `country`, `traffic_source`, `device_type`, `browser` | Multi-dimensional segmentation reports |
| `mv_daily_utm` | Daily | `events` | `tenant_id`, `event_date`, `utm_source`, `utm_medium`, `utm_campaign` | UTM attribution analysis |
| `mv_hourly_unique_visitors` | Hourly | `events` | `tenant_id`, `event_date`, `hour` | Unique visitor counts (using `uniqState(visitor_id)`) |

- MVs use `AggregatingMergeTree` engine with `*State` / `*Merge` combinators for incremental aggregation.
- MVs are populated automatically on insert into the source `events` table — no separate ETL pipeline required.
- MV storage overhead estimated at ~5–10% of raw event data (aggregated rows are far fewer than raw events).
- MV partition key aligned with source table: `toYYYYMM(event_date)` for consistent partition pruning.

#### 2. Redis Cluster (Query-Result Cache)

| Design Element | Decision | Rationale |
|---|---|---|
| **Technology** | Redis Cluster (6+ nodes, 3 masters + 3 replicas) | HA via automatic failover; horizontal partitioning of cache keys |
| **Cache key** | `SHA256(tenant_id + query_hash + time_range_bucket)` | Tenant isolation; deterministic deduplication; time bucketing for freshness |
| **TTL** | 10 minutes (default); 60 minutes for queries on fully-closed time periods | Aligns with batch processing window (A-1: 50–100 min); closed periods are immutable |
| **Serialization** | MessagePack | Compact binary format; faster than JSON; supports complex result structures |
| **Max memory per node** | 16 GB | Sufficient for top-N query results; LRU eviction for long-tail queries |
| **Cache-aside pattern** | Query API checks Redis first → on miss, query ClickHouse (MV or raw) → write result to Redis | Standard cache-aside; no write-through to avoid stale-on-write complexity |
| **Warm-up** | Pre-populate cache for top-100 tenants' default dashboards on batch completion | Ensures cache is warm for highest-traffic tenants after each processing cycle |

#### 3. Query Routing Logic

```
Request → Query API
  ├─ Redis cache lookup (by cache key)
  │   ├─ HIT → return cached result (<10 ms)
  │   └─ MISS ↓
  ├─ Route to appropriate ClickHouse target:
  │   ├─ Query matches MV pattern → query pre-aggregated MV table
  │   └─ Ad-hoc / non-standard query → query raw events table
  ├─ Write result to Redis (with TTL)
  └─ Return result to client
```

- Query API includes a **query classifier** that maps incoming dashboard requests to the best MV or falls back to raw table.
- Cache bypass header supported for debugging and testing (`X-Cache-Bypass: true`).

#### 4. Cache Failure Resilience

- Redis Cluster uses `CLUSTER FAILOVER` for automatic master promotion (A-2).
- On total cache failure: Query API falls through to ClickHouse directly — degraded latency but no data loss or outage.
- Circuit breaker on Redis: if Redis latency > 100 ms, bypass cache for that request to avoid compounding latency.

Supersedes: none.

## Consequences

- ✅ Materialized views reduce per-query scan volume by 100–1000× for common dashboard patterns, achieving sub-second response even without cache (P-1, RISK-QUERY-02).
- ✅ Redis result cache absorbs repeated identical queries at <10 ms, reducing ClickHouse read load by estimated 60–80% for cache-eligible queries (P-1, RISK-QUERY-01).
- ✅ Combined strategy targets >90% of dashboard queries completing under 500 ms (well within 1.5s P95) at peak 1,318 RPS (P-1).
- ✅ Cache-aside with graceful degradation ensures 99.9% uptime — cache failure degrades latency, not availability (A-2).
- ✅ 10-minute default TTL aligned with batch freshness window (A-1); closed time periods cached for 60 minutes are safe since data is immutable.
- ⚠️ Materialized views add DDL management overhead — schema changes to raw events require corresponding MV updates.
- ⚠️ MV storage overhead (~5–10% of raw data) must be accounted for in hot-tier capacity planning (ADR-0007).
- ⚠️ High-cardinality ad-hoc queries that don't match MV patterns will bypass pre-aggregation and hit raw tables — these must be monitored for latency compliance.
- ⚠️ Redis Cluster adds infrastructure (6+ nodes); operational burden includes memory monitoring, eviction tuning, and failover testing.
- **Follow-ups:** ADR-0009 (OLAP Engine and Read Path Architecture) will define the complete Query API service design and tenant-aware query routing. ADR-0012 (Observability) will define cache hit-rate monitoring and query latency SLO dashboards.
