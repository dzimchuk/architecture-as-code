# 13. Design Data Privacy and Compliance Architecture

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Design the architecture for GDPR/CCPA compliance — consent management, data subject rights (access, deletion, portability), audit logging, and data lineage tracking — across the distributed analytics pipeline (Edge Collectors → Kafka → ClickHouse with 3 storage tiers → Redis cache → materialized views).
- **Business drivers:** The platform collects behavioral data from website visitors across tenant sites, subject to GDPR (EU), CCPA (California), and similar privacy regulations. Non-compliance exposes the business to fines up to 4% of annual turnover (GDPR) or $7,500/violation (CCPA). Data subjects must be able to withdraw consent (effective within 1 hour), request data access, and request deletion (completed within 30 days). All data access/modification operations must be recorded in an immutable audit trail retained for 7 years. The distributed nature of the platform — data residing across Kafka topics, 3 ClickHouse tiers, Redis cache, and materialized views — makes deletion and consent propagation non-trivial.
- **Relevant QAs (IDs):**
  - SE-1 — Security (Data Privacy): consent respected within 1 hour of update; deletion requests completed within 30 days; 100% of data operations logged with immutable audit trail retained for 7 years
- **Relevant Risks:**
  - RISK-GDPR-01 — Deletion requests cannot complete within 30 days due to distributed data copies across Kafka, ClickHouse tiers (hot/warm/cold S3), Redis cache, and materialized views
- **Depends on:** ADR-0005 (Kafka, 72h retention), ADR-0006 (ClickHouse), ADR-0007 (tiered storage with GDPR deletion workflow), ADR-0008 (Redis cache, materialized views), ADR-0012 (observability for audit monitoring)

### Compliance Requirements

| Requirement | Target | Source |
|---|---|---|
| Consent propagation | <1 hour from update | SE-1 |
| Deletion completion | <30 days from request | SE-1 |
| Data access response | <30 days from request | GDPR Art. 15 |
| Audit trail coverage | 100% of data access/modification operations | SE-1 |
| Audit trail retention | 7 years, immutable | SE-1 |
| Data portability format | Machine-readable (JSON/CSV) | GDPR Art. 20 |

### Data Locations Requiring Compliance

| Location | Data Type | Deletion Complexity |
|---|---|---|
| Edge Collectors (in-flight) | Raw events in WAL buffer | Low — TTL expires in 1 hour |
| Kafka (`events.ingest`) | Raw events | Low — 72h retention auto-expires (ADR-0005) |
| Kafka (`events.dlq`) | Failed events | Medium — manual DLQ drain required |
| ClickHouse hot tier | Raw events + MVs | Medium — async mutation (ADR-0007) |
| ClickHouse warm tier | Raw events + MVs | Medium — async mutation |
| ClickHouse cold tier (S3) | Raw events | High — S3 part rewrite required |
| Redis cache | Query results | Low — TTL expires in 10–60 min (ADR-0008) |
| Materialized views | Aggregated data | High — aggregates may embed visitor data |

## Decision

### Compare Consent and Deletion Architecture Approaches

| Criterion | A: Decentralized (Each Service Handles Own Compliance) | B: Centralized Compliance Service (Single Orchestrator) | C: Event-Driven Compliance (Compliance Events on Kafka) |
|---|---|---|---|
| **Deletion Completeness** | 🟥 Risk of missed locations; no single source of truth for deletion status | 🟩 Orchestrator tracks all locations; verifies completion | 🌟 Compliance events consumed by all services; each confirms completion; orchestrator aggregates |
| **Consent Propagation (<1h)** | 🟥 Propagation delay varies per service; no coordination | 🟩 Centralized push to all services | 🌟 Kafka-based propagation; all consumers react independently; <1h achievable |
| **Audit Trail Integrity** | 🟥 Fragmented logs across services; hard to correlate | 🌟 Single audit log; complete lifecycle tracking | 🟩 Audit events on Kafka; consumed by central audit store |
| **Operational Complexity** | 🟩 No additional service | 🟨 Central service to manage; but clear ownership | 🟨 Compliance topics + consumer logic per service |
| **Failure Recovery** | 🟥 No coordination for retrying failed deletions | 🟩 Orchestrator retries failed steps; tracks state | 🟩 Kafka replay enables retry of failed compliance events |
| **Cross-Tier Coordination** | 🟥 Each tier manages independently; gaps likely | 🌟 Orchestrator coordinates hot→warm→cold deletion sequence | 🟩 Each tier consumer processes events; orchestrator verifies |
| **Scalability** | 🟩 Distributed load | 🟨 Central service may bottleneck under high deletion volume | 🟩 Kafka-based; scales with partition count |

### Evaluation Summary

- **Option A** is eliminated — decentralized compliance in a 7+ location distributed system risks incomplete deletions and fragmented audit trails, creating regulatory exposure.
- **Option B** provides strong orchestration and audit control but centralizes all compliance logic in a single service.
- **Option C** combines event-driven scalability with centralized orchestration — compliance events propagate via Kafka for scalable distribution, while a central orchestrator tracks lifecycle completion and maintains the audit trail.

### Decision

Adopt **Option C: Event-Driven Compliance Architecture with Central Orchestrator**.

#### 1. Consent Management Service

| Design Element | Decision | Rationale |
|---|---|---|
| **Consent store** | PostgreSQL (ACID, strong consistency) | Consent state must be authoritative and consistent; not suitable for eventual-consistency stores |
| **Consent API** | REST API for tenant CMP (Consent Management Platform) integration | Standard integration pattern; CMPs call API on visitor consent change |
| **Consent propagation** | Publish `consent.updated` event to Kafka topic on every change | All downstream consumers (Edge Collectors, ClickHouse consumers) react to consent changes |
| **Propagation latency** | <1 hour (Kafka consumer lag + service processing) | SE-1 requirement; Kafka consumer lag typically <1 min |
| **Consent model** | Per-visitor, per-purpose, per-tenant | Granular consent per GDPR Art. 6/7; purposes: analytics, marketing, functional |
| **Consent cache** | Edge Collectors cache consent state locally (refreshed every 5 min) | Sub-second consent check during event ingestion without hitting central store |

#### 2. Deletion Orchestration

```
Data Subject Request → Compliance API
  ├── Record request in audit log (status: RECEIVED)
  ├── Publish `deletion.requested` to Kafka (compliance.deletions topic)
  │
  ├── Step 1: Invalidate Redis cache entries for visitor
  │     └── Redis consumer: DEL matching keys → confirm to orchestrator
  │
  ├── Step 2: Delete from ClickHouse (all tiers)
  │     ├── Execute ALTER TABLE events DELETE WHERE visitor_id = Y
  │     ├── Execute ALTER TABLE mv_* DELETE WHERE visitor_id = Y (where applicable)
  │     ├── Async mutation propagates through hot → warm → cold (S3 part rewrite)
  │     └── ClickHouse consumer: confirm mutation completion → orchestrator
  │
  ├── Step 3: Kafka data expiry (passive)
  │     └── 72h retention (ADR-0005) auto-expires; no active deletion needed
  │
  ├── Step 4: Edge Collector WAL expiry (passive) 
  │     └── 1h WAL retention auto-expires; no active deletion needed
  │
  ├── Orchestrator: verify all active steps completed
  │     ├── Retry failed steps (max 3 retries, exponential backoff)
  │     └── Escalate to ops team if retries exhausted
  │
  └── Record completion in audit log (status: COMPLETED, timestamp)
      └── Target: complete within 14 days (buffer vs. 30-day SLA)
```

#### 3. Data Subject Access Request (DSAR)

| Step | Action | Output |
|---|---|---|
| 1 | Receive request via Compliance API | Request logged in audit trail |
| 2 | Query ClickHouse: `SELECT * FROM events WHERE visitor_id = Y` (hot + warm tiers) | Raw event data |
| 3 | Query cold tier if historical data requested | Archived event data |
| 4 | Export to machine-readable format (JSON Lines or CSV) | Downloadable file |
| 5 | Deliver via secure download link (signed URL, 7-day expiry) | Tenant-accessible link |
| 6 | Record access in audit log | Compliance evidence |

#### 4. Immutable Audit Log

| Design Element | Decision | Rationale |
|---|---|---|
| **Storage** | Append-only table in ClickHouse (`AuditLog` with `ReplicatedMergeTree`, no TTL) + S3 backup | ClickHouse handles high write volume; S3 backup for 7-year immutability |
| **Immutability** | Write-once table (no UPDATE/DELETE allowed via application RBAC); S3 Object Lock for backup | Regulatory requirement for tamper-proof audit trail |
| **Retention** | 7 years (SE-1); automated archival to S3 Glacier after 1 year | Cost-efficient long-term retention |
| **Schema** | `timestamp, request_id, tenant_id, visitor_id, action_type, component, status, actor, details` | Full traceability for compliance audits |
| **Coverage** | Every consent change, deletion request, DSAR, data access, admin action | 100% coverage per SE-1 |

#### 5. Materialized View Deletion Handling

| MV Type | Visitor Data Present? | Deletion Strategy |
|---|---|---|
| `mv_hourly_page_views` | No (page-level aggregation) | No deletion needed |
| `mv_daily_segmentation` | No (dimension-level aggregation) | No deletion needed |
| `mv_daily_utm` | No (campaign-level aggregation) | No deletion needed |
| `mv_hourly_unique_visitors` | Yes (`uniqState(visitor_id)`) | Re-aggregate from source after deletion; or accept statistical approximation |

For `mv_hourly_unique_visitors`: the `uniqState` HyperLogLog sketch cannot remove individual elements. After raw event deletion, schedule a periodic re-aggregation job (weekly) from source data to rebuild affected MV partitions. Between re-aggregation cycles, unique visitor counts may slightly overcount deleted visitors — an acceptable statistical deviation for privacy compliance since the raw data (PII) is deleted.

Supersedes: none.

## Consequences

- ✅ Event-driven compliance via Kafka ensures scalable propagation across all services without centralized bottleneck (SE-1, RISK-GDPR-01).
- ✅ Central orchestrator tracks deletion lifecycle across all 7+ data locations, with retry logic preventing incomplete deletions (RISK-GDPR-01).
- ✅ 14-day internal target provides 16-day buffer against the 30-day regulatory SLA (SE-1).
- ✅ Consent propagation via Kafka + local caching at Edge Collectors achieves <1 hour latency (SE-1).
- ✅ Immutable audit log (ClickHouse + S3 Object Lock) satisfies 7-year tamper-proof retention (SE-1).
- ✅ Passive expiry of Kafka (72h) and Edge Collector WAL (1h) eliminates active deletion for transient data stores — reduces orchestration scope.
- ✅ PostgreSQL-backed consent store provides ACID consistency for the authoritative consent state.
- ⚠️ ClickHouse `ALTER TABLE DELETE` triggers async mutations with part rewrites — heavy deletion workloads on cold S3 tier may take hours; 14-day target accounts for this.
- ⚠️ HyperLogLog-based `uniqState` MVs cannot precisely remove individual visitors; periodic re-aggregation is required, accepting interim statistical overcount.
- ⚠️ Compliance orchestrator is a critical service — failure blocks deletion processing; requires HA deployment (multi-AZ per ADR-0011) and dead-letter handling for failed compliance events.
- ⚠️ DSAR exports for high-volume visitors may produce large datasets; query timeout and export size limits must be configured.
- **Follow-ups:** ADR-0014 (Client SDK Design) will define consent-aware event collection on the client side. Encryption at rest/in transit policies require a dedicated security hardening ADR.
