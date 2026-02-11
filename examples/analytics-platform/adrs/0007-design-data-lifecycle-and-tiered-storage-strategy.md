# 7. Design Data Lifecycle and Tiered Storage Strategy

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Define the data lifecycle management strategy — hot/warm/cold storage tiers, automated data migration policies, compression settings, backup procedures, and cost optimization — for the ClickHouse-based event store accumulating ~99 TB by Year 5 with forever retention.
- **Business drivers:** Data per website must be stored forever (business requirement). Cumulative storage grows from 16 TB/year (Year 1) to 24 TB/year (Year 5), totaling ~99 TB. Without tiering and cost optimization, storage costs scale linearly and become unsustainable. Older data is accessed less frequently but must remain queryable for compliance and historical analysis.
- **Relevant QAs (IDs):**
  - S-2 — Scalability (Storage): store cumulative 99 TB by Year 5 with automated tiering (hot SSD <3 mo, warm HDD 3–12 mo, cold object storage >12 mo)
  - D-1 — Durability: zero data loss with 11 nines durability via multi-AZ replication and backup to object storage
  - P-1 — Performance (Query Latency): ≤1.5s P95 for queries over ≤3-month periods (hot tier performance critical)
  - A-2 — Availability: 99.9% uptime; storage failures must not cause data loss or extended outage
  - SE-1 — Security (Data Privacy): GDPR/CCPA deletion requests completed within 30 days across all tiers
- **Relevant Risks:**
  - RISK-STORAGE-01 — Cumulative 99 TB by Year 5; single storage tier cannot handle volume cost-effectively
  - RISK-STORAGE-02 — Forever retention drives unsustainable storage costs without lifecycle policies
  - RISK-DATA-01 — Data loss during node failures or deployment updates
  - RISK-GDPR-01 — Deletion requests across distributed data copies and storage tiers
- **Depends on:** ADR-0006 (ClickHouse with ReplicatedMergeTree selected as event store)

### Storage Volume Projections

| Year | Annual Ingestion (TB) | Cumulative Logical (TB) | Est. Compressed (TB, ~5×) | Hot Tier (TB) | Warm Tier (TB) | Cold Tier (TB) |
|---|---|---|---|---|---|---|
| 1 | 16.2 | 16.2 | 3.2 | 3.2 | 0 | 0 |
| 2 | 17.8 | 34.0 | 6.8 | 3.6 | 3.2 | 0 |
| 3 | 19.6 | 53.6 | 10.7 | 3.9 | 3.6 | 3.2 |
| 4 | 21.6 | 75.2 | 15.0 | 4.3 | 3.9 | 6.8 |
| 5 | 23.7 | 98.9 | 19.8 | 4.7 | 4.3 | 10.7 |

*Note: Compressed estimates assume ~5× average columnar compression (LZ4 for hot, ZSTD for warm/cold). Actual ratios depend on data cardinality.*

## Decision

### Compare Tiered Storage Approaches

| Criterion | A: ClickHouse Native Tiered Storage (volume policies) | B: Application-Level ETL (ClickHouse → Parquet → S3) | C: Separate Databases per Tier (ClickHouse hot + dedicated cold store) |
|---|---|---|---|
| **Operational Simplicity** | 🌟 Declarative TTL + volume policies in table DDL; ClickHouse handles migration automatically | 🟨 Requires custom ETL pipeline, scheduling, validation | 🟥 Multiple systems to manage; query federation needed |
| **Query Transparency** | 🌟 Single table abstraction; queries span tiers seamlessly | 🟥 Cold data requires separate query path or federation layer | 🟨 Requires query routing logic or union views |
| **Storage Cost Efficiency** | 🟩 SSD → HDD → S3; ClickHouse manages lifecycle | 🟩 Parquet on S3 is cost-optimal for cold data | 🟩 Each system optimized for its tier |
| **Data Consistency** | 🌟 Single system of record; no cross-system sync | 🟨 ETL introduces eventual consistency; risk of stale/missing data | 🟥 Cross-system consistency requires coordination |
| **GDPR Deletion Across Tiers** | 🟩 Single system; lightweight delete or partition drop | 🟨 Must delete from ClickHouse + find/rewrite Parquet files on S3 | 🟥 Must coordinate deletion across independent systems |
| **Compression Control** | 🟩 Per-column codec; different codecs per volume (LZ4 hot, ZSTD cold) | 🟩 Parquet compression is excellent (Snappy/ZSTD) | 🟨 Depends on each system's capabilities |
| **Backup / Restore** | 🟩 ClickHouse backup to S3; restore from any tier | 🟨 Hot backup from ClickHouse; cold already on S3 | 🟨 Independent backup procedures per system |
| **Maturity** | 🟩 GA in ClickHouse since v22.8; S3-backed storage since v22.3 | 🟩 Standard data engineering pattern; well-understood | 🟨 Federated queries less mature |

### Evaluation Summary

- **Option A (ClickHouse Native Tiered Storage)** provides the simplest operational model with declarative TTL-based tier migration, transparent multi-tier queries, single-system consistency, and streamlined GDPR deletion. It avoids the complexity of custom ETL pipelines or cross-system query federation.
- **Option B** offers optimal cold-storage cost via Parquet on S3 but introduces ETL pipeline complexity, consistency risks, and complicates GDPR deletion.
- **Option C** maximizes per-tier optimization but creates unacceptable operational burden and cross-system coordination requirements.

### Decision

Adopt **ClickHouse Native Tiered Storage** with three storage tiers managed via volume policies and TTL rules.

#### Tier Definitions

| Tier | Media | Data Age | Compression | Retention | Use Case |
|---|---|---|---|---|---|
| **Hot** | NVMe SSD | < 3 months | LZ4 | Active | Dashboard queries (P-1 ≤1.5s); real-time analytics |
| **Warm** | HDD / EBS gp3 | 3–12 months | ZSTD (level 3) | Active | Historical reports; trend analysis; moderate query latency acceptable |
| **Cold** | S3-compatible object storage | > 12 months | ZSTD (level 7) | Forever | Compliance, audit, rare ad-hoc historical queries; higher latency accepted |

#### ClickHouse Storage Configuration

```sql
-- Storage policy definition (config.xml / config.d/)
-- hot_volume: local NVMe SSD
-- warm_volume: local HDD or network-attached block storage  
-- cold_volume: S3-compatible object storage

-- Table TTL rules
ALTER TABLE events
    MODIFY TTL
        event_date + INTERVAL 3 MONTH TO VOLUME 'warm_volume',
        event_date + INTERVAL 12 MONTH TO VOLUME 'cold_volume';
```

#### Compression Strategy

| Tier | Codec | Rationale |
|---|---|---|
| Hot (SSD) | LZ4 | Fast decompression; minimal CPU overhead; optimizes query latency |
| Warm (HDD) | ZSTD level 3 | Balanced compression ratio (~7–10×) and decompression speed |
| Cold (S3) | ZSTD level 7 | Maximum compression (~10–20×); decompression speed less critical for rare queries |

#### Backup and Disaster Recovery

| Component | Strategy | RPO | RTO |
|---|---|---|---|
| Hot tier | ClickHouse `BACKUP` to S3; daily full + hourly incremental | 1 hour | <4 hours |
| Warm tier | ClickHouse `BACKUP` to S3; daily incremental | 24 hours | <8 hours |
| Cold tier | Already on S3; cross-region replication enabled | 0 (durable) | <24 hours |
| Kafka replay | 72-hour retention in Kafka (ADR-0005) enables re-ingestion for recent data | 0 for last 72h | ~processing lag |

#### GDPR Deletion Workflow (Cross-Tier)

| Step | Action | Scope |
|---|---|---|
| 1 | Receive deletion request; record in compliance audit log | All tiers |
| 2 | Execute `ALTER TABLE events DELETE WHERE tenant_id = X AND visitor_id = Y` | Hot + Warm (local ClickHouse) |
| 3 | ClickHouse asynchronous mutation propagates delete through MergeTree parts | Automatic |
| 4 | For cold S3 parts: mutation rewrites affected parts excluding deleted rows | Cold tier |
| 5 | Verify deletion across all tiers; update audit log with completion timestamp | All tiers |
| 6 | Target: complete within 14 days (buffer against 30-day SLA) | SE-1 compliance |

#### Cost Optimization Measures

| Measure | Impact | Tier |
|---|---|---|
| Columnar compression (LZ4/ZSTD) | Reduces 99 TB logical → ~10–20 TB physical | All |
| S3-compatible cold storage | ~$0.023/GB/month vs. ~$0.10/GB for SSD | Cold |
| Monthly partitioning with TTL-based migration | Automated; no manual data movement | All |
| Drop pre-aggregation source data after materialized view refresh | Reduces hot tier churn (future ADR-0008) | Hot |
| S3 Intelligent-Tiering or Glacier for data >3 years | Further cost reduction for oldest data | Cold |

Supersedes: none.

## Consequences

- ✅ Declarative TTL rules automate hot→warm→cold migration with zero custom ETL (S-2, RISK-STORAGE-01).
- ✅ S3-backed cold storage with ZSTD compression keeps forever-retention cost sustainable (~$0.023/GB/month for compressed cold data) (S-2, RISK-STORAGE-02).
- ✅ Single ClickHouse table abstraction enables transparent queries across all tiers — no federation layer required (P-1).
- ✅ Hot tier on NVMe SSD preserves ≤1.5s query latency for the 3-month dashboard window (P-1, RISK-QUERY-01).
- ✅ Multi-AZ replication (RF=2 per shard) + S3 backup + Kafka replay provides layered durability beyond 11 nines (D-1, RISK-DATA-01).
- ✅ Single-system deletion mutations simplify GDPR compliance across all tiers (SE-1, RISK-GDPR-01).
- ⚠️ Cold-tier S3 queries are significantly slower (seconds to minutes); users must be informed that historical queries >12 months may have degraded latency.
- ⚠️ Large DELETE mutations on MergeTree trigger part rewrites; heavy deletion workloads may impact write/merge performance temporarily.
- ⚠️ S3 egress costs during cold-tier queries must be monitored; frequent cold-tier access patterns should trigger promotion to warm tier.
- ⚠️ Backup restore time for full dataset (~20 TB compressed) requires multi-hour recovery window; Kafka replay covers the most recent 72 hours.
- **Follow-ups:** ADR-0008 (Query Optimization and Caching Strategy) will define materialized views and pre-aggregation to reduce hot-tier scan volume. ADR-0013 (Data Privacy and Compliance Architecture) will detail the full GDPR deletion pipeline.
