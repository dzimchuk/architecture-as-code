# ADD 3.0 — Iteration Plan Draft

**Mode:** Attribute-Driven Design (ADD 3.0) — Iteration Planning  
**System:** Analytics Platform  
**Date:** 2026-02-11  
**Basis:** QARs from `docs/src/10_quality_requirements.adoc`, Risks from `docs/src/11_technical_risks.adoc`, Existing ADRs 0001–0003

## Quality Tree (Summary)

| ID | Quality Attribute | Priority |
|----|-------------------|----------|
| P-1 | Performance (Query Latency) | High |
| P-2 | Performance (Write Throughput) | High |
| S-1 | Scalability (Horizontal) | High |
| S-2 | Scalability (Storage) | High |
| A-1 | Availability (Data Freshness) | Medium |
| A-2 | Availability (System Uptime) | High |
| D-1 | Durability (Data Retention) | High |
| M-1 | Maintainability (Monitoring) | Medium |
| U-1 | Usability (SDK Integration) | Medium |
| SE-1 | Security (Data Privacy) | High |

## Iteration Plan

| Iteration Goal | Architectural Drivers | Candidate Tactics | Planned ADRs | Traceability |
|---|---|---|---|---|
| **1 — Core Ingestion Architecture**: Establish the distributed ingestion pipeline capable of sustaining 1.16M–5.08M write RPS | **Business:** Platform must ingest ~100B events/day from tenant websites with zero data loss during peak bursts. **QAs:** P-2 (5M peak write RPS), S-1 (100B→146B events/day growth), D-1 (zero data loss for acknowledged events). **Risks:** RISK-INGEST-01 (write throughput mind-blowing tier), RISK-INGEST-02 (peak burst event loss), RISK-SCALE-01 (autoscaling lag during spikes) | Distributed message queue with horizontal partitioning; Multi-stage buffering with dead-letter queues; Backpressure management with circuit breakers; Rate limiting per tenant; Predictive autoscaling with warm standby capacity (10–20% buffer); Producer acknowledgment guarantees (acks=all) | ADR-0004: Message Queue Technology Selection; ADR-0005: Ingestion Pipeline Architecture and Partitioning Strategy | P-2, S-1, D-1, RISK-INGEST-01, RISK-INGEST-02, RISK-SCALE-01 |
| **2 — Storage and Data Lifecycle**: Design the sharded storage architecture and tiered retention strategy for ~99 TB cumulative by Year 5 | **Business:** Forever data retention per website; cumulative storage must remain cost-sustainable over 5 years. **QAs:** S-2 (99 TB cumulative by Year 5), D-1 (zero data loss, 11 nines durability), A-2 (99.9% uptime requires resilient storage). **Risks:** RISK-STORAGE-01 (single DB cannot handle 99 TB), RISK-STORAGE-02 (forever retention cost escalation), RISK-DATA-01 (data loss during node failures) | Sharded/partitioned database with horizontal scaling; Tiered storage (hot SSD <3 mo, warm HDD 3–12 mo, cold object storage >12 mo); Multi-AZ replication (RF=3); Automated archival and data lifecycle policies; Compression (Zstd/LZ4); Zero-downtime deployment strategies | ADR-0006: Distributed Database Technology Selection; ADR-0007: Data Lifecycle and Tiered Storage Strategy | S-2, D-1, A-2, RISK-STORAGE-01, RISK-STORAGE-02, RISK-DATA-01 |
| **3 — Query Performance and Caching**: Achieve ≤1.5s P95 query latency for multi-dimensional segmentation over 3-month periods under peak read load (900–1,318 RPS) | **Business:** Analysts/marketers require fast dashboard responses across geolocation, traffic source, device, and UTM dimensions. **QAs:** P-1 (≤1.5s P95 query latency), A-2 (99.9% uptime under peak read load). **Risks:** RISK-QUERY-01 (query latency exceeds 1.5s SLA at peak), RISK-QUERY-02 (complex multi-dimensional queries degrade performance) | Pre-aggregated materialized views; Distributed caching layer with cache invalidation strategy; Read replicas for query offloading; Columnar storage format (Parquet) with partition pruning; OLAP query pushdown and secondary indexes; Query result caching with TTL | ADR-0008: Query Optimization and Caching Strategy; ADR-0009: OLAP Engine and Read Path Architecture | P-1, A-2, RISK-QUERY-01, RISK-QUERY-02 |
| **4 — Processing Pipeline, Availability, and Observability**: Design the event processing pipeline (batch/stream), multi-AZ availability, and end-to-end observability stack | **Business:** Events must appear in dashboards within 50–100 minutes; system must maintain 99.9% uptime during business hours; operations team needs bottleneck detection within 2 minutes. **QAs:** A-1 (50–100 min freshness), A-2 (99.9% uptime, ≤43 min downtime/month), M-1 (≤2 min bottleneck detection). **Risks:** RISK-FRESH-01 (batch window violated under peak), RISK-OPS-01 (1M+ RPS requires senior expertise), RISK-OPS-02 (monitoring delays), RISK-NETWORK-01 (bandwidth approaching 40 Gbps threshold) | Batch processing pipeline with stream processing fallback for critical metrics; Multi-AZ deployment with automatic failover; Unified observability stack (metrics, logs, distributed traces at ≥1% sampling); SLO/SLA dashboards with anomaly detection; Runbooks and chaos engineering practices; Multi-region ingestion distribution for bandwidth management | ADR-0010: Event Processing Pipeline Strategy (Batch vs. Stream); ADR-0011: High Availability and Multi-AZ Deployment Architecture; ADR-0012: Observability and Monitoring Architecture | A-1, A-2, M-1, RISK-FRESH-01, RISK-OPS-01, RISK-OPS-02, RISK-NETWORK-01 |
| **5 — Security, Compliance, and SDK Integration**: Implement GDPR/CCPA compliance architecture and lightweight client SDK integration | **Business:** Must comply with data privacy regulations; website owners must integrate tracking in <30 minutes with zero server-side changes. **QAs:** SE-1 (consent within 1 hr, deletion within 30 days, 7-year audit trail), U-1 (≤30 min integration, <50 KB SDK payload). **Risks:** RISK-GDPR-01 (deletion requests across distributed data copies cannot complete within 30 days) | Centralized consent management service with real-time propagation; Data lineage tracking for distributed deletion workflows; Tombstone markers and compliance audit trail; Lightweight SDK with async event dispatch; Script-tag integration with domain whitelisting; Immutable audit logging with 7-year retention | ADR-0013: Data Privacy and Compliance Architecture; ADR-0014: Client SDK Design and Integration Strategy | SE-1, U-1, RISK-GDPR-01 |
