# 3. Estimate System Growth and Technical Risks

Date: 2026-02-04

## Status

Proposed

## Context

Following ADR-0002's parameter identification, this ADR presents back-of-the-envelope calculations for the Analytics Platform's 5-year capacity requirements. The calculations are based on:

- Initial volume: 100 billion events/day
- Growth rate: +10% year-over-year
- Peak traffic multiplier: ×3 (for write workloads)
- Analytics users: 100,000 initial users (growing with event volume)
- Average event size: ~0.5 KB
- Data retention: Forever (cumulative storage)

These estimates support evaluation against Quality Attribute Requirements:
- **QAR-1**: Reports within 1.5 seconds (impacts read RPS capacity)
- **QAR-2**: ~100 billion events/day ingestion (impacts write RPS and network bandwidth)
- **QAR-3**: 50–100 minute freshness delay acceptable (allows for batch processing strategies)
- **QAR-4**: Forever retention (drives cumulative storage growth)

### Scaling Tier Reference

| Tier            | CPU (RPS) | RAM    | Disk   | Network (aggregate) |
|-----------------|-----------|--------|--------|---------------------|
| 🟩 Minuscule    | 10        | 128 GB | 1 TB   | 1 Gbps              |
| 🟩 A few        | 100       | 512 GB | 10 TB  | 10 Gbps             |
| 🟨 Something    | 1,000     | 1 TB   | 100 TB | 40 Gbps             |
| 🟥 A lot        | 10,000    | 10 TB  | 1 PB   | 100 Gbps            |
| 🟥 OMG          | 100,000   | 100 TB | 10 PB  | 400 Gbps            |
| 🟥 Mind-blowing | 1,000,000 | 1 PB   | 1 EB   | ≥1 Tbps             |

## Decision

### Projection Table

| Year | # Events/Day | # Events/Year | Event DB Size (TB) | # Analytics Users | Write RPS | Peak Write RPS | Real-Time Read RPS | Real-Time Peak Read RPS | Aggregated Read RPS | Aggregated Peak Read RPS | Write Network BW (GB/s) | Read Network BW (GB/s) | Total Network BW (GB/s) |
|------|--------------|---------------|-------------------|-------------------|-----------|----------------|-------------------|------------------------|--------------------|-----------------------|------------------------|----------------------|------------------------|
| 1    | 100B         | 36.5T         | 16.21 🟨          | 100,000           | 1,157,407 🟥 | 3,472,222 🟥 | 150 🟩            | 450 🟨                 | 150 🟩             | 450 🟨                | 0.54 🟩                | 0.42 🟩              | 0.96 🟩                |
| 2    | 110B         | 40.2T         | 17.83 🟨          | 110,000           | 1,273,148 🟥 | 3,819,444 🟥 | 165 🟩            | 495 🟨                 | 165 🟩             | 495 🟨                | 0.59 🟩                | 0.46 🟩              | 1.05 🟩                |
| 3    | 121B         | 44.2T         | 19.61 🟨          | 121,000           | 1,400,463 🟥 | 4,201,389 🟥 | 182 🟩            | 545 🟨                 | 182 🟩             | 545 🟨                | 0.65 🟩                | 0.51 🟩              | 1.16 🟨                |
| 4    | 133B         | 48.6T         | 21.57 🟨          | 133,100           | 1,540,509 🟥 | 4,621,528 🟥 | 200 🟩            | 599 🟨                 | 200 🟩             | 599 🟨                | 0.72 🟩                | 0.56 🟩              | 1.28 🟨                |
| 5    | 146B         | 53.4T         | 23.73 🟨          | 146,410           | 1,694,560 🟥 | 5,083,681 🟥 | 220 🟩            | 659 🟨                 | 220 🟩             | 659 🟨                | 0.79 🟩                | 0.61 🟩              | 1.40 🟨                |

**Note:** Cumulative Event DB Size across all years by Year 5: ~99 TB 🟨

**Legend:** 🟩 Low Risk · 🟨 Medium Risk · 🟥 High Risk

### Calculation Details

**Write RPS (Average):**
- Formula: `# of events per day / 86,400 seconds`
- Year 1: 100,000,000,000 / 86,400 = 1,157,407 RPS
- Year 5: 146,410,000,000 / 86,400 = 1,694,560 RPS

**Peak Write RPS:**
- Formula: `Average Write RPS × 3 (peak multiplier)`
- Year 1: 1,157,407 × 3 = 3,472,222 RPS
- Year 5: 1,694,560 × 3 = 5,083,681 RPS

**Event Database Size (per year):**
- Formula: `# of events per year × 0.5 KB / 1,024^4`
- Year 1: 36,500,000,000,000 × 0.5 KB = 16.21 TB
- Cumulative by Year 5: 98.96 TB

**Read RPS:**
- Assumptions: Real-time and aggregated analytics each serve concurrent user queries
- Conservative estimate: 150 RPS baseline growing with user base (+10% YoY)
- Peak read: 3× multiplier during business hours

**Network Bandwidth:**
- Write: `Write RPS × 0.5 KB` (event ingestion)
- Read: `Read RPS × estimated response size` (query results)
- Total: Write + Read bandwidth

## Consequences

### Critical Risks (🟥 High)

**1. Write Throughput is Mind-blowing Tier**
- Write RPS ranges from **1.16M to 1.69M** RPS (average), peaking at **3.47M to 5.08M** RPS
- This exceeds the "OMG" tier (100K RPS) by **10-50×**
- **Impact:** No single database or message queue can handle this write load without extreme horizontal partitioning
- **Implication:** Requires distributed ingestion architecture (Kafka clusters, sharded write paths, multi-region distribution)
- **Operational Complexity:** Very high; requires expertise in managing massive-scale distributed systems

**2. Peak Write Load Amplification**
- Peak multiplier of ×3 creates burst capacity requirement that may be difficult to provision elastically
- **Impact:** Infrastructure must handle 5M RPS spikes without data loss or backpressure failures
- **Implication:** Need buffering layers (Kafka topics, SQS queues) with sufficient capacity headroom (5-10× normal throughput)

### Medium Risks (🟨 Moderate)

**3. Storage Growth is Manageable but Cumulative**
- Event database size grows from **16.2 TB to 23.7 TB per year**, cumulative **~99 TB by Year 5**
- Fits within "Something" tier (10-100 TB) but requires tiered storage strategy
- **Impact:** Forever retention drives long-term storage costs; older data should migrate to cold storage (S3 Glacier, Azure Archive)
- **Implication:** Need data lifecycle policies, partitioning by date, and archival automation

**4. Network Bandwidth Escalation**
- Total bandwidth grows from **0.96 GB/s to 1.40 GB/s** (~7.7 to 11.2 Gbps)
- Within "A few" to "Something" tier but approaching 40 Gbps threshold by Year 5
- **Impact:** Single datacenter or availability zone may experience bandwidth saturation
- **Implication:** Consider multi-region ingestion distribution and CDN/edge caching for read workloads

**5. Peak Read RPS Approaching Scaling Threshold**
- Real-time and aggregated peak read RPS: **450 to 659 RPS** each (900-1,318 total)
- Near "Something" tier boundary (1,000 RPS)
- **Impact:** Query latency may degrade during peak usage if database lacks sufficient read replicas
- **Implication:** Need caching layer (Redis/Memcached) and read replicas to meet QAR-1 (1.5s latency)

### Low Risks (🟩 Acceptable)

**6. Average Read RPS is Manageable**
- Real-time and aggregated read RPS: **150-220 RPS** each (300-440 total)
- Well within "A few" tier (100-1,000 RPS)
- **Impact:** Standard database configurations with modest caching can handle this load
- **Implication:** No immediate scaling concerns for average read workloads

**7. Write Network Bandwidth is Sustainable**
- Write bandwidth: **0.54-0.79 GB/s** (~4.3-6.3 Gbps)
- Within "A few" tier (1-10 Gbps)
- **Impact:** Standard network infrastructure sufficient for ingestion path
- **Implication:** No special high-speed networking required for write path

### Cost and Operational Notes

- **Infrastructure Cost:** Write throughput dominates cost structure; expect significant Kafka/Kinesis and distributed database expenses
- **Team Expertise Required:** Managing 1M+ RPS systems requires senior-level distributed systems engineering
- **Monitoring Complexity:** Need sophisticated observability stack to detect bottlenecks across distributed ingestion pipeline
- **Data Retention Cost:** Forever retention requires cost optimization through tiered storage (hot → warm → cold)
- **Testing Complexity:** Load testing at 5M RPS peak requires dedicated performance testing infrastructure

### Architectural Implications (Not Decisions)

These calculations suggest the system will likely need:
- Distributed message queue (Kafka/Kinesis/Pulsar) for write buffering
- Sharded/partitioned database architecture (Cassandra, ScyllaDB, ClickHouse, or similar)
- Multi-tier storage strategy (SSD → HDD → Object Storage)
- Caching layer for read workloads (Redis/Memcached)
- Multi-region deployment for geographic load distribution
- Batch processing pipeline for aggregations (vs. real-time computation)

Specific technology choices will be addressed in subsequent ADRs focusing on component selection and deployment architecture.
