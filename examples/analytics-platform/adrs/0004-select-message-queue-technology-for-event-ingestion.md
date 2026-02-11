# 4. Select Message Queue Technology for Event Ingestion

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Select a distributed message queue technology to serve as the write-buffering backbone of the Analytics Platform ingestion pipeline.
- **Business drivers:** The platform must ingest ~100 billion events/day from tenant websites, growing to 146 billion events/day by Year 5 (+10% YoY). Zero data loss is required for acknowledged events, including during peak traffic bursts (3× multiplier). Infrastructure must be operationally sustainable for a mid-sized engineering team.
- **Relevant QAs (IDs):**
  - P-2 — Write Throughput: sustain 5M peak write RPS (Year 5 projection)
  - S-1 — Horizontal Scalability: scale from 100B to 146B events/day over 5 years
  - D-1 — Durability: zero data loss for acknowledged events (11 nines durability)
- **Relevant Risks:**
  - RISK-INGEST-01 — Write throughput at mind-blowing tier (1.16M–1.69M avg RPS, peaks 3.47M–5.08M RPS); no single system handles this without extreme horizontal partitioning
  - RISK-INGEST-02 — Peak bursts (3× multiplier) may cause event loss or backpressure failures
  - RISK-SCALE-01 — Autoscaling lag during traffic spikes causing temporary capacity shortfall

### Key Requirements

| Requirement | Threshold | Source |
|---|---|---|
| Average write RPS | 1.16M–1.69M | ADR-0003, P-2 |
| Peak write RPS | 3.47M–5.08M | ADR-0003, P-2 |
| Event size | ~0.5 KB | ADR-0002 |
| Write bandwidth | 0.54–0.79 GB/s avg, ~2.4 GB/s peak | ADR-0003 |
| Durability guarantee | Zero loss for acked events | D-1 |
| Horizontal scalability | Linear scale-out via partitioning | S-1 |
| Retention in queue | Hours to days (buffer before DB write) | Operational |
| Dead-letter queue support | Required for failed events | RISK-INGEST-02 |

## Decision

### Compare Message Queue Technologies

| Criterion | Apache Kafka | Apache Pulsar | Amazon Kinesis Data Streams | Redpanda | Amazon MSK (Managed Kafka) |
|---|---|---|---|---|---|
| **Max Throughput (single cluster)** | 🌟 Millions of msg/s; proven at LinkedIn, Uber scale | 🟩 Millions of msg/s; tiered storage decouples compute/storage | 🟨 Shard-limited (~1 MB/s per shard); requires thousands of shards | 🟩 Kafka-compatible; claims higher per-node throughput | 🟩 Kafka throughput with managed operations |
| **Horizontal Scalability** | 🌟 Partition-based; add brokers + partitions linearly | 🟩 Segment-based; brokers stateless, bookies scale independently | 🟨 Add shards but resharding is disruptive | 🟩 Partition-based; Kafka-compatible scaling | 🟩 Partition-based; AWS handles broker scaling |
| **Durability (acks=all)** | 🌟 ISR replication (RF=3), acks=all, fsync configurable | 🟩 BookKeeper quorum writes, WAL-based | 🟩 Synchronous replication across 3 AZs (built-in) | 🟩 Raft-based replication, fsync by default | 🟩 Inherits Kafka replication model |
| **Dead-Letter Queue** | 🟩 Via consumer-side DLQ topics (manual config) | 🌟 Native DLQ + retry topics built-in | 🟨 Requires Lambda/custom error handling | 🟩 Kafka-compatible DLQ pattern | 🟩 Kafka-compatible DLQ pattern |
| **Backpressure Handling** | 🟩 Producer buffering, configurable retries, idempotent producer | 🟩 Built-in rate limiting, flow control | 🟨 Throttling via shard limits; less flexible | 🟩 Kafka-compatible backpressure | 🟩 Kafka-compatible backpressure |
| **Operational Complexity** | 🟨 Requires ZooKeeper (or KRaft); significant ops burden at scale | 🟥 BookKeeper + ZooKeeper; highest operational complexity | 🌟 Fully managed; zero infrastructure ops | 🟩 Single binary, no ZooKeeper; simpler operations | 🟩 AWS-managed; reduced ops vs. self-hosted Kafka |
| **Multi-Region Support** | 🟩 MirrorMaker 2 / Confluent Replicator | 🟩 Native geo-replication built-in | 🟩 Cross-region replication via AWS | 🟨 Community-stage geo-replication | 🟩 Cross-region via MirrorMaker 2 |
| **Ecosystem & Tooling** | 🌟 Kafka Connect, Schema Registry, ksqlDB, massive ecosystem | 🟩 Pulsar IO, Schema Registry, Pulsar Functions | 🟨 AWS-specific (Firehose, Lambda); vendor lock-in | 🟨 Growing; Kafka-compatible but smaller community | 🟩 Full Kafka ecosystem + AWS integrations |
| **Cost at Target Scale** | 🟩 Infrastructure cost; no license fees | 🟨 Higher infra cost (BookKeeper cluster) | 🟥 Per-shard pricing; extremely expensive at 5M RPS | 🟩 Lower infra cost (higher per-node efficiency) | 🟨 AWS managed premium on top of infra cost |
| **Maturity at >1M RPS** | 🌟 Proven at multiple hyperscale companies | 🟩 Proven at Yahoo, Tencent, Splunk | 🟨 Not designed for >1M RPS without massive shard counts | 🟨 Growing adoption; fewer hyperscale references | 🟩 Inherits Kafka's proven scalability |

### Evaluation Summary

- **Apache Kafka** scores highest across throughput, durability, ecosystem, and maturity at the required scale (1M+ RPS). It is the de facto standard for event streaming at hyperscale. The primary drawback is operational complexity, which can be mitigated by the KRaft mode (eliminating ZooKeeper) or by deploying via a managed service.
- **Amazon Kinesis** is eliminated due to per-shard cost scaling and throughput limitations at 5M peak RPS.
- **Apache Pulsar** offers strong capabilities but introduces higher operational complexity (BookKeeper) with fewer hyperscale production references.
- **Redpanda** is a compelling alternative with simpler operations, but has fewer proven deployments at the target scale.
- **Amazon MSK** provides a managed Kafka option but adds AWS vendor dependency and cost premium.

### Decision

Adopt **Apache Kafka (KRaft mode)** as the message queue technology for the ingestion pipeline.

- Deploy with KRaft (no ZooKeeper dependency) for simplified cluster management.
- Configure `acks=all` with `min.insync.replicas=2` (RF=3) to guarantee zero data loss for acknowledged events.
- Use idempotent producers (`enable.idempotence=true`) to prevent duplicate writes during retries.
- Implement DLQ topics for events that fail processing after configurable retry attempts.
- Reserve managed Kafka (MSK or Confluent Cloud) as a fallback option if operational burden exceeds team capacity.

Supersedes: none.

## Consequences

- ✅ Proven throughput at >1M RPS with linear horizontal scaling via partitions (P-2, S-1).
- ✅ Zero data loss guarantee with `acks=all` + ISR replication (D-1, RISK-INGEST-02).
- ✅ Largest ecosystem for connectors, schema management, and stream processing (reduces integration risk).
- ✅ KRaft mode eliminates ZooKeeper dependency, reducing operational surface (RISK-INGEST-01).
- ⚠️ Operational complexity remains significant at 5M RPS scale; dedicated Kafka SRE expertise required (RISK-OPS-01).
- ⚠️ Partition count planning is critical — under-partitioning limits parallelism, over-partitioning increases metadata overhead.
- ⚠️ If self-managed operations prove unsustainable, migration path to MSK/Confluent Cloud must be validated.
- **Follow-ups:** ADR-0005 (Ingestion Pipeline Architecture and Partitioning Strategy) will define topic layout, partition count, consumer group design, and multi-region ingestion topology.
