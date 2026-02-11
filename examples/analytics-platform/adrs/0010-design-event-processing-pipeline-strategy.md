# 10. Design Event Processing Pipeline Strategy

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Decide the event processing model — batch, stream, or hybrid — that transforms raw events from Kafka into aggregated data in ClickHouse materialized views, ensuring events appear in analytics dashboards within the 50–100 minute freshness window while remaining resilient under peak ingestion load.
- **Business drivers:** The platform accepts 50–100 minute delays between a user action and its appearance in statistics (business requirement). This tolerance enables batch-oriented aggregation. However, pipeline failures or peak-load backlogs must not extend the processing window beyond 100 minutes, or the freshness SLA is violated. The pipeline must also populate the pre-aggregated materialized views defined in ADR-0008 without disrupting the write path.
- **Relevant QAs (IDs):**
  - A-1 — Availability (Data Freshness): events appear in dashboards within 50–100 minutes of occurrence
  - P-2 — Performance (Write Throughput): pipeline must keep pace with 1.16M–1.69M avg RPS ingestion
  - A-2 — Availability (System Uptime): 99.9% uptime; processing pipeline failures must not cause data loss or extended downtime
- **Relevant Risks:**
  - RISK-FRESH-01 — Batch processing window (50–100 min) violated under peak load or pipeline failures; processing lag >100 min
  - RISK-OPS-01 — Managing 1M+ RPS distributed system requires senior-level expertise; additional processing systems increase operational surface
- **Depends on:** ADR-0004 (Kafka), ADR-0005 (ingestion pipeline, 72h retention), ADR-0006 (ClickHouse), ADR-0008 (materialized views)

### Processing Requirements

| Requirement | Value | Source |
|---|---|---|
| End-to-end freshness SLA | 50–100 minutes | A-1 |
| Raw event ingestion rate | 1.16M–1.69M avg RPS | ADR-0003 |
| Kafka retention (replay buffer) | 72 hours | ADR-0005 |
| MV population | 4 materialized views (ADR-0008) | ADR-0008 |
| Acceptable processing lag | <100 minutes under peak load | A-1, RISK-FRESH-01 |

## Decision

### Step 1: Compare Processing Model Categories

| Criterion | Pure Batch | Pure Stream | Hybrid (Batch-Primary + Stream-Fallback) | Lambda Architecture (Batch + Stream Parallel) |
|---|---|---|---|---|
| **Freshness (50–100 min SLA)** | 🟩 Micro-batch at 10–30 min intervals fits within window | 🌟 Sub-minute freshness; far exceeds requirement | 🟩 Batch meets SLA; stream activates only for critical metrics or lag recovery | 🌟 Streaming path provides real-time; batch provides corrections |
| **Operational Complexity** | 🟩 Simplest; scheduled jobs with clear boundaries | 🟨 Requires always-on stream processing cluster; state management, checkpointing | 🟨 Two modes but stream path activated conditionally; simpler than full Lambda | 🟥 Dual pipelines; reconciling batch/stream results; highest complexity |
| **Resource Efficiency** | 🌟 Processes data in bulk; highly efficient per-event cost | 🟨 Continuous resource consumption; idle capacity during low traffic | 🟩 Batch-efficient by default; stream resources only when needed | 🟥 Dual resource allocation; both running continuously |
| **Peak Load Resilience** | 🟨 Batch jobs accumulate backlog; lag increases linearly | 🟩 Continuous processing absorbs peaks if scaled appropriately | 🟩 Batch handles normal load; stream activates to drain lag during peaks | 🟩 Both paths handle peaks independently |
| **Failure Recovery** | 🟩 Re-run failed batch from Kafka offset; idempotent | 🟨 Checkpoint-based recovery; more complex failure modes | 🟩 Batch re-run + stream replay from Kafka; layered recovery | 🟨 Must recover both paths independently |
| **ClickHouse MV Compatibility** | 🟩 Batch insert triggers MV population naturally | 🟩 Streaming inserts also trigger MVs | 🟩 Both modes trigger MVs on insert | 🟨 Must coordinate MV updates from two sources |
| **Team Expertise Required (RISK-OPS-01)** | 🟩 Standard batch ETL skills; lower barrier | 🟨 Stream processing expertise (Flink/Spark Streaming) required | 🟨 Batch skills primary; stream expertise for fallback path | 🟥 Both batch and stream expertise required continuously |

**Result:** **Hybrid (Batch-Primary + Stream-Fallback)** provides the optimal balance — batch processing meets the 50–100 min SLA with operational simplicity, while a conditional stream path prevents SLA violations during peak-load backlogs.

### Step 2: Compare Batch Processing Technologies

| Criterion | ClickHouse Native (Kafka Engine + MV) | Apache Spark (Structured Streaming / Batch) | Apache Flink | Custom Kafka Consumer Service |
|---|---|---|---|---|
| **Integration with ClickHouse** | 🌟 Native; Kafka Engine reads topics directly; MVs populated on insert | 🟨 Requires JDBC/ClickHouse connector; external batch writes | 🟨 Requires ClickHouse sink connector; external writes | 🟩 Direct async insert API; full control over batching |
| **Throughput at 1M+ RPS** | 🟩 ClickHouse handles high-throughput bulk inserts natively | 🟩 Proven at massive scale; micro-batch model | 🌟 Continuous processing; highest throughput for stream workloads | 🟩 Custom tuning possible; depends on implementation |
| **Operational Overhead** | 🌟 No additional infrastructure; runs inside ClickHouse cluster | 🟨 Spark cluster (YARN/K8s); job scheduling; driver/executor management | 🟨 Flink cluster (standalone/K8s); checkpoint storage; job manager | 🟩 Stateless pods on K8s; lightweight deployment |
| **Micro-Batch Control** | 🟨 Limited; Kafka Engine polls continuously; less control over batch boundaries | 🟩 Configurable trigger intervals; structured micro-batching | 🟩 Windowed processing with configurable triggers | 🟩 Full control over batch size, flush intervals |
| **Backfill / Replay** | 🟨 Kafka Engine can reset offsets but limited orchestration | 🟩 Read from specific offsets; robust backfill support | 🟩 Savepoint-based replay; flexible offset management | 🟩 Custom offset management; full replay control |
| **Exactly-Once Semantics** | 🟨 At-least-once (Kafka Engine); dedup via ReplacingMergeTree | 🟩 Exactly-once with checkpointing | 🌟 Native exactly-once with checkpointing | 🟩 Idempotent writes via dedup key |
| **Monitoring / Observability** | 🟨 ClickHouse system tables; limited job-level metrics | 🟩 Spark UI, metrics, structured streaming dashboard | 🟩 Flink dashboard, metrics, backpressure indicators | 🟩 Custom metrics via Prometheus; full control |
| **Cost** | 🌟 Zero additional infra cost | 🟥 Spark cluster compute + storage | 🟥 Flink cluster compute + checkpoint storage | 🟩 Lightweight K8s pods; minimal overhead |

### Evaluation Summary

- **ClickHouse Native (Kafka Engine + MV)** provides the simplest path with zero additional infrastructure. However, it offers limited control over micro-batch boundaries and provides at-least-once semantics requiring deduplication.
- **Apache Spark/Flink** add powerful processing capabilities but introduce separate cluster infrastructure — unjustified given the platform's processing needs are primarily bulk insert + aggregation, not complex transformation.
- **Custom Kafka Consumer Service** provides full control over batching behavior, replay, and monitoring with minimal infrastructure footprint (stateless K8s pods).

### Decision

Adopt a **Hybrid Batch-Primary architecture** using a **two-layer approach**:

#### Layer 1: ClickHouse Kafka Engine (Primary Continuous Ingest)

- ClickHouse Kafka Engine consumes directly from `events.ingest` topic, inserting raw events into the `events` table.
- Materialized views (ADR-0008) are populated automatically on each insert batch.
- Continuous consumption with `kafka_max_block_size=65536` and `kafka_poll_timeout_ms=5000` for tunable micro-batching.
- At-least-once delivery; deduplication handled via `ReplacingMergeTree` with `(tenant_id, event_id)` as dedup key.

#### Layer 2: Custom Backfill Consumer (Stream-Fallback for Lag Recovery)

- Stateless Kafka consumer service deployed on Kubernetes (auto-scaled).
- Activated conditionally when Kafka consumer lag exceeds 30 minutes of event volume (trigger threshold for RISK-FRESH-01).
- Reads from `events.ingest` at configurable offsets; writes to ClickHouse via async insert API.
- Deactivated automatically when lag drops below 10 minutes.
- Also used for on-demand backfill (replaying from Kafka's 72-hour retention window after incidents).

#### Processing Flow

```
Kafka (events.ingest)
  ├── ClickHouse Kafka Engine (Layer 1 — continuous, primary)
  │     ├── INSERT into events table
  │     └── Triggers MV population (mv_hourly_page_views, mv_daily_segmentation, etc.)
  │
  └── Backfill Consumer (Layer 2 — conditional, lag recovery)
        ├── Activated when consumer lag > 30 min
        ├── Async bulk INSERT into events table
        └── Deactivated when lag < 10 min
```

#### Freshness Budget

| Stage | Latency | Notes |
|---|---|---|
| Event occurrence → Edge Collector | ~1–5 seconds | ADR-0005 |
| Collector → Kafka | ~1–10 seconds | Batching + produce |
| Kafka → ClickHouse (Kafka Engine) | ~5–30 seconds | Poll interval + block size |
| MergeTree merge + MV aggregation | ~1–5 minutes | Background merge process |
| **Total (normal operation)** | **~2–10 minutes** | Well within 50–100 min SLA |
| **Total (peak with lag)** | **~30–60 minutes** | Backfill consumer activated at 30 min lag |

Supersedes: none.

## Consequences

- ✅ ClickHouse Kafka Engine eliminates need for a separate processing cluster (Spark/Flink), reducing operational surface area (RISK-OPS-01).
- ✅ Normal-operation freshness of 2–10 minutes is well within the 50–100 minute SLA (A-1).
- ✅ Conditional backfill consumer prevents SLA violation during peak-load backlogs by draining lag before it exceeds 100 minutes (RISK-FRESH-01).
- ✅ 72-hour Kafka retention (ADR-0005) enables full replay/backfill without data loss after processing incidents (A-2).
- ✅ MVs populated automatically on insert — no separate aggregation jobs required (ADR-0008 compatibility).
- ✅ At-least-once delivery with `ReplacingMergeTree` dedup is acceptable for analytics aggregation where exact counts are approximated via `uniqState`.
- ⚠️ ClickHouse Kafka Engine consumer offset management is less flexible than dedicated consumer groups; offset reset requires table recreation.
- ⚠️ Backfill consumer activation logic requires robust lag monitoring and automated scaling — false activations waste resources; late activations risk SLA breach.
- ⚠️ At-least-once semantics mean duplicate events may briefly inflate raw counts before MergeTree background merge deduplicates; MVs using `*State` combinators handle this correctly.
- **Follow-ups:** ADR-0011 (HA Architecture) will address Kafka Engine failover across AZs. ADR-0012 (Observability) will define consumer lag monitoring, backfill activation alerts, and freshness SLO tracking.
