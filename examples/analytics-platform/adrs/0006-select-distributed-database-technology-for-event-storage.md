# 6. Select Distributed Database Technology for Event Storage

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Select a distributed database technology to serve as the primary event store for the Analytics Platform, consuming events from the Kafka ingestion pipeline (ADR-0004, ADR-0005) and supporting both write-heavy ingestion and analytical read queries.
- **Business drivers:** The platform must persist ~100B–146B events/day with forever retention, accumulating ~99 TB by Year 5. The database must sustain 1.16M–1.69M average write RPS (from Kafka consumers), serve analytical queries with ≤1.5s P95 latency, and maintain 99.9% uptime. Data loss is unacceptable for acknowledged events.
- **Relevant QAs (IDs):**
  - P-1 — Query Latency: reports delivered within 1.5s P95 for multi-dimensional segmentation over ≤3 months
  - P-2 — Write Throughput: sustain 1.16M–1.69M avg write RPS from Kafka consumers
  - S-1 — Horizontal Scalability: linear scale-out from 100B to 146B events/day
  - S-2 — Scalability (Storage): store cumulative 99 TB by Year 5 with forever retention
  - D-1 — Durability: zero data loss, 11 nines durability via multi-AZ replication
  - A-2 — Availability: 99.9% uptime during business hours
- **Relevant Risks:**
  - RISK-STORAGE-01 — Cumulative 99 TB by Year 5; single DB cannot handle volume
  - RISK-STORAGE-02 — Forever retention drives unsustainable storage costs
  - RISK-QUERY-01 — Query latency exceeds 1.5s SLA during peak read load
  - RISK-QUERY-02 — Complex multi-dimensional queries degrade performance
  - RISK-DATA-01 — Data loss during node failures or deployment updates
- **Depends on:** ADR-0004 (Kafka as message queue), ADR-0005 (ingestion pipeline with `events.ingest` topic, `tenant_id` partition key)

### Storage and Query Requirements

| Requirement | Value | Source |
|---|---|---|
| Write RPS (from Kafka consumers) | 1.16M–1.69M avg | ADR-0003, P-2 |
| Event size | ~0.5 KB | ADR-0002 |
| Annual storage per year | 16–24 TB | ADR-0003 |
| Cumulative storage (Year 5) | ~99 TB | ADR-0003, S-2 |
| Query latency (P95) | ≤1.5 seconds | P-1 |
| Peak read RPS | 900–1,318 (combined real-time + aggregated) | ADR-0003 |
| Query dimensions | Geolocation, traffic source, device, browser, UTM tags, time | P-1 |
| Query time range | Up to 3 months | P-1 |
| Retention | Forever | D-1 |
| Replication | Multi-AZ, RF≥3 | D-1, A-2 |

## Decision

### Step 1: Compare Database Model Categories

| Criterion | Columnar OLAP | Wide-Column NoSQL | Time-Series DB | Row-Oriented RDBMS |
|---|---|---|---|---|
| **Analytical Query Performance** | 🌟 Designed for aggregation, filtering, GROUP BY over large datasets | 🟨 Fast scans but limited aggregation pushdown | 🟩 Optimized for time-range queries; weaker on multi-dimensional | 🟥 Not designed for analytical scans over billions of rows |
| **Write Throughput (1M+ RPS)** | 🟩 Batch-oriented inserts; high throughput via async merges | 🌟 Designed for massive write throughput (LSM-tree) | 🟩 High append throughput for time-indexed data | 🟥 Row-level ACID limits write throughput at this scale |
| **Multi-Dimensional Queries** | 🌟 Columnar pruning + secondary indexes + materialized views | 🟨 Requires denormalization; limited ad-hoc query support | 🟨 Limited to time + few tag dimensions | 🟩 Flexible SQL but slow at scale |
| **Horizontal Scalability** | 🟩 Sharded clusters; linear scale-out | 🌟 Native partitioning and replication; proven at massive scale | 🟩 Clustered; scale-out varies by product | 🟨 Sharding is complex and often manual |
| **Storage Efficiency (99 TB)** | 🌟 Columnar compression (10–20× typical); excellent for 99 TB | 🟩 Compression available; higher raw footprint than columnar | 🟩 Good compression for time-series; variable for event data | 🟥 Row storage is space-inefficient for analytics |
| **Tiered Storage Support** | 🟩 Some products support hot/cold tiering natively | 🟨 Manual tiering or TTL-based deletion | 🟩 Retention policies; some support object storage offload | 🟥 Limited native tiering |
| **Ecosystem / SQL Support** | 🟩 SQL or SQL-like interfaces | 🟨 CQL or custom query languages; limited joins | 🟨 InfluxQL/Flux; non-standard | 🌟 Full SQL compliance |

**Result:** **Columnar OLAP** is the strongest fit — purpose-built for analytical aggregation queries over large datasets with high write throughput, columnar compression for storage efficiency, and multi-dimensional query support.

### Step 2: Compare Columnar OLAP Database Products

| Criterion | ClickHouse | Apache Druid | Apache Pinot | DuckDB | StarRocks |
|---|---|---|---|---|---|
| **Write Throughput (1M+ RPS)** | 🌟 Proven >1M rows/s per node via async inserts and MergeTree engine | 🟩 High ingestion via real-time + batch; Kafka ingestion native | 🟩 High throughput; Kafka ingestion native; proven at LinkedIn scale | 🟥 Single-node; not designed for distributed writes | 🟩 High throughput; compatible with ClickHouse MergeTree |
| **Query Latency (P95 ≤1.5s)** | 🌟 Sub-second for pre-aggregated queries; vectorized execution | 🟩 Sub-second for time-series aggregations; bitmap indexes | 🟩 Sub-second with star-tree indexes; optimized for real-time | 🟩 Fast for local analytics; not distributed | 🟩 Vectorized engine; sub-second for aggregations |
| **Multi-Dimensional Segmentation** | 🌟 Rich SQL with JOINs, secondary indexes, materialized views, projections | 🟨 Dimension-based but limited SQL; no JOINs | 🟩 Star-tree indexes for multi-dimensional; limited SQL | 🟩 Full SQL but single-node | 🟩 Full MySQL-compatible SQL; materialized views |
| **Horizontal Scalability** | 🟩 Sharded clusters (ReplicatedMergeTree); linear scale-out | 🟩 Segment-based distribution; independent scaling of ingestion/query | 🟩 Segment-based; independent scaling | 🟥 Single-node only | 🟩 Shared-nothing; horizontal scale-out |
| **Storage Efficiency / Compression** | 🌟 LZ4/ZSTD columnar compression; 10–20× typical ratio; parts-based storage | 🟩 Columnar with compression; segment-based | 🟩 Columnar compression; segment-based | 🟩 Columnar with compression | 🟩 Columnar compression; comparable to ClickHouse |
| **Tiered Storage (hot/warm/cold)** | 🟩 Native tiered storage policies (disk → S3); TTL per partition | 🟩 Deep storage on S3/HDFS; segment lifecycle management | 🟩 Tiered storage with object storage offload | 🟥 Single-node file-based | 🟨 Growing tiered storage support; less mature |
| **Kafka Integration** | 🟩 Kafka engine for direct consumption; also materialized views from Kafka | 🌟 Native Kafka indexing service; real-time ingestion | 🌟 Native Kafka consumer; real-time ingestion with upserts | 🟥 No native Kafka support | 🟩 Routine load from Kafka |
| **Replication / Durability** | 🟩 ReplicatedMergeTree with ZooKeeper/ClickHouse Keeper; multi-AZ | 🟩 Deep storage provides durability; segment replication | 🟩 Segment replication; deep storage for durability | 🟥 No replication | 🟩 Multi-replica with consistency guarantees |
| **Operational Maturity** | 🌟 Large community; ClickHouse Cloud (managed); proven at Yandex, Cloudflare, Uber | 🟩 Apache project; managed options (Imply); proven at Airbnb, Netflix | 🟩 Apache project; managed (StarTree); proven at LinkedIn, Uber | 🟨 Embedded use cases; not for distributed production | 🟨 Growing adoption; fewer hyperscale references |
| **Multi-Tenancy** | 🟩 Database-per-tenant or row-level via tenant column + partition key | 🟨 Datasource-per-tenant; higher overhead | 🟩 Table-per-tenant or tenant column; tenant-aware routing | 🟥 Not applicable | 🟩 Tenant isolation via databases or row-level |
| **Cost at 99 TB** | 🟩 Open-source; ClickHouse Cloud for managed; compression reduces actual storage | 🟨 Requires ZooKeeper + deep storage infra; higher operational cost | 🟨 Requires ZooKeeper + deep storage; moderate cost | 🟩 Free but not applicable at scale | 🟨 Open-source; managed options emerging |

### Evaluation Summary

- **ClickHouse** scores highest across write throughput, query performance, multi-dimensional SQL support, storage efficiency, and operational maturity at hyperscale. It is the only candidate with proven >1M rows/s per-node ingestion, full SQL support with JOINs and materialized views, and native tiered storage to S3.
- **Apache Druid** and **Apache Pinot** are strong real-time OLAP alternatives with native Kafka ingestion, but offer weaker SQL support and higher operational complexity (ZooKeeper + deep storage coordination).
- **DuckDB** is eliminated — single-node only, not suitable for distributed 99 TB workloads.
- **StarRocks** is a capable ClickHouse-compatible alternative but has fewer production references at hyperscale.

### Decision

Adopt **ClickHouse** (ReplicatedMergeTree engine with ClickHouse Keeper) as the primary distributed event store.

- **Engine:** `ReplicatedMergeTree` with `ClickHouse Keeper` (replaces ZooKeeper) for replication coordination.
- **Partition key:** `toYYYYMM(event_date)` — monthly partitions for efficient time-range pruning and TTL-based tiering.
- **Order key (primary key):** `(tenant_id, event_date, event_type)` — optimized for tenant-scoped, time-bounded, event-type-filtered analytical queries.
- **Sharding:** Distributed table across cluster shards; shard key = `cityHash64(tenant_id)` for even tenant distribution.
- **Replication:** RF=2 per shard (each shard has 2 replicas across AZs); combined with Kafka replay capability provides effective RF=3+ durability.
- **Compression:** `LZ4` for hot data (faster decompression), `ZSTD` for warm/cold data (higher compression ratio).
- **Kafka consumption:** ClickHouse Kafka engine or dedicated consumer service writing via async inserts (`async_insert=1`, `wait_for_async_insert=0`) for batched high-throughput writes.
- **Managed option:** ClickHouse Cloud reserved as fallback if self-managed operations exceed team capacity.

Supersedes: none.

## Consequences

- ✅ Proven write throughput >1M rows/s per node enables handling 1.69M avg RPS across a modest cluster (P-2, RISK-STORAGE-01).
- ✅ Columnar compression (10–20×) reduces 99 TB logical to ~5–10 TB physical storage, significantly mitigating cost risk (S-2, RISK-STORAGE-02).
- ✅ Vectorized query execution + monthly partition pruning + materialized views support ≤1.5s P95 query latency for 3-month ranges (P-1, RISK-QUERY-01, RISK-QUERY-02).
- ✅ Native tiered storage policies enable automated hot→cold migration to S3-compatible object storage (S-2, RISK-STORAGE-02).
- ✅ `ReplicatedMergeTree` with multi-AZ replicas ensures zero data loss for persisted events (D-1, RISK-DATA-01).
- ✅ Full SQL with JOINs, subqueries, and window functions supports complex multi-dimensional segmentation without denormalization (P-1).
- ⚠️ ClickHouse Keeper cluster requires operational attention; 3-node Keeper ensemble minimum for HA.
- ⚠️ MergeTree async merge process can cause temporary read amplification during heavy write periods; requires monitoring of merge queue depth.
- ⚠️ No native ACID transactions — eventual consistency between replicas is acceptable for analytics but requires awareness in consumer design.
- ⚠️ `tenant_id`-based sharding may create hot shards for high-volume tenants; tenant-level monitoring and potential re-sharding strategy needed.
- **Follow-ups:** ADR-0007 (Data Lifecycle and Tiered Storage Strategy) will define hot/warm/cold policies, TTLs, and archival workflows. ADR-0008 (Query Optimization and Caching Strategy) will define materialized views, pre-aggregations, and caching layers on top of ClickHouse.
