# 12. Design Observability and Monitoring Architecture

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Select and design the unified observability stack — metrics, logs, distributed traces, alerting, and SLO dashboards — that enables the operations team to detect bottlenecks and anomalies within 2 minutes across the entire distributed pipeline (Edge Collectors → Kafka → ClickHouse → Query API → Redis → Analytics UI).
- **Business drivers:** The platform operates at 1M+ RPS with a distributed architecture spanning 3 AZs, 7+ component types, and 1,024 Kafka partitions. Without comprehensive observability, operational incidents escalate undetected, MTTR increases, on-call burden grows, and SLA compliance cannot be verified. The operations team requires actionable visibility, not just raw telemetry.
- **Relevant QAs (IDs):**
  - M-1 — Maintainability (Monitoring): bottleneck detection latency ≤2 minutes; metrics retention 90 days; distributed trace sampling ≥1%; alert false positive rate <5%
  - A-2 — Availability (System Uptime): 99.9% uptime requires fast detection and response; observability is a prerequisite for failover validation
- **Relevant Risks:**
  - RISK-OPS-01 — Managing 1M+ RPS distributed system requires senior-level expertise; observability reduces the expertise barrier by making system behavior transparent
  - RISK-OPS-02 — Monitoring complexity across distributed pipeline delays bottleneck detection; bottleneck detection time >5 min; alert false positive rate >10%
- **Depends on:** ADR-0004 (Kafka), ADR-0005 (Edge Collectors), ADR-0006 (ClickHouse), ADR-0008 (Redis), ADR-0009 (Query API), ADR-0011 (multi-AZ deployment)

### Observability Requirements

| Requirement | Target | Source |
|---|---|---|
| Bottleneck detection latency | ≤2 minutes | M-1 |
| Metrics retention | 90 days | M-1 |
| Distributed trace sampling | ≥1% of requests | M-1 |
| Alert false positive rate | <5% | M-1 |
| Component coverage | All 7+ component types across 3 AZs | M-1, ADR-0011 |

## Decision

### Step 1: Compare Observability Stack Approaches

| Criterion | A: Fully Managed (Datadog / New Relic) | B: Open-Source Self-Hosted (Prometheus + Grafana + Jaeger + Loki) | C: Cloud-Native Managed (AWS CloudWatch + X-Ray + OpenSearch) | D: Open-Source + Managed Storage (Prometheus/Grafana Cloud + Tempo + Loki) |
|---|---|---|---|---|
| **Metrics at 1M+ RPS Scale** | 🌟 Handles high cardinality; auto-scaling ingestion | 🟩 Prometheus federation/Thanos for scale; proven at high cardinality | 🟨 CloudWatch custom metrics expensive at scale; cardinality limits | 🟩 Grafana Cloud handles scale; Mimir for self-hosted alternative |
| **Distributed Tracing (≥1%)** | 🌟 Built-in APM; auto-instrumentation; tail-based sampling | 🟩 Jaeger/Tempo; manual instrumentation; head-based sampling | 🟨 X-Ray limited to AWS-native; sampling less flexible | 🟩 Tempo with head/tail sampling; OpenTelemetry compatible |
| **Log Aggregation** | 🌟 Built-in log management with correlation | 🟩 Loki for log aggregation; label-based indexing | 🟨 CloudWatch Logs; cross-service correlation limited | 🟩 Loki (managed or self-hosted); efficient for high volume |
| **Alerting (<5% FP rate)** | 🟩 ML-based anomaly detection; low FP with tuning | 🟩 Alertmanager with configurable rules; requires manual tuning | 🟨 CloudWatch Alarms; basic threshold-based; higher FP rate | 🟩 Grafana Alerting; multi-source rules; anomaly detection plugins |
| **SLO/SLA Dashboards** | 🌟 Built-in SLO tracking, burn-rate alerts | 🟩 Grafana SLO plugin; Sloth for SLO-as-code | 🟨 Custom dashboards; no native SLO framework | 🟩 Grafana Cloud SLO; native support |
| **Vendor Lock-in** | 🟥 Proprietary agents, APIs, query language | 🌟 Fully open; OpenTelemetry compatible; portable | 🟥 AWS-locked; non-portable | 🟩 OpenTelemetry compatible; portable data layer; managed convenience |
| **Operational Overhead** | 🌟 Zero infra ops; SaaS | 🟥 Significant; Prometheus/Thanos/Jaeger clusters to manage at 1M+ RPS scale | 🟩 Managed by AWS | 🟩 Managed storage; minimal ops overhead |
| **Cost at Scale** | 🟥 High; per-host + per-metric + per-span pricing escalates at 1M+ RPS | 🟩 Infrastructure cost only; no per-metric fees | 🟨 Per-metric + per-log-GB; moderate at scale | 🟨 Grafana Cloud usage-based pricing; lower than Datadog at this scale |
| **OpenTelemetry Support** | 🟩 OTLP ingestion supported | 🌟 Native OTel ecosystem; collector + exporters | 🟨 X-Ray has limited OTel support | 🌟 Full OTel native; collector + all exporters |

### Evaluation Summary

- **Option A (Datadog/New Relic)** provides the richest out-of-box experience but vendor lock-in and per-unit pricing make it cost-prohibitive at 1M+ RPS with high-cardinality metrics across 1,024 Kafka partitions.
- **Option B (Full Self-Hosted)** eliminates licensing costs but introduces significant operational burden managing Prometheus federation, Jaeger storage, and Loki at this scale — contradicts RISK-OPS-01.
- **Option C (AWS CloudWatch)** is limited in distributed tracing flexibility and creates cloud vendor lock-in.
- **Option D** balances open-source portability (OpenTelemetry) with managed storage (reducing ops burden), providing strong SLO support and cost efficiency at scale.

### Decision

Adopt **Option D: OpenTelemetry + Grafana Stack (managed storage)** as the unified observability platform.

#### Architecture Components

| Layer | Technology | Role |
|---|---|---|
| **Telemetry Collection** | OpenTelemetry Collector (per-node DaemonSet + gateway) | Unified collection of metrics, traces, logs via OTLP |
| **Metrics** | Prometheus (scrape) → Grafana Mimir (long-term storage) | High-cardinality metrics; 90-day retention; PromQL |
| **Traces** | OpenTelemetry SDK → Grafana Tempo | Distributed traces; 1% head-based + tail-based sampling for errors |
| **Logs** | OpenTelemetry Collector → Grafana Loki | Label-indexed log aggregation; correlated with traces via TraceID |
| **Dashboards** | Grafana | Unified dashboards, SLO tracking, alerting |
| **Alerting** | Grafana Alerting + Alertmanager | Multi-source alert rules; PagerDuty/Slack integration |
| **SLO Management** | Grafana SLO + Sloth (SLO-as-code) | SLO definitions, error budgets, burn-rate alerts |

#### Instrumentation per Component

| Component | Metrics | Traces | Logs | Key SLIs |
|---|---|---|---|---|
| **Edge Collectors** | Inbound RPS, error rate, WAL depth, Kafka produce latency | Request traces (sampled) | Error logs, rate-limit events | Ingestion success rate, producer latency P99 |
| **Kafka** | Broker metrics (JMX), consumer lag, partition ISR, topic throughput | N/A (infrastructure) | Broker logs, replication errors | Consumer group lag, under-replicated partitions |
| **ClickHouse (write)** | Insert RPS, merge queue depth, replication lag, disk usage per tier | Insert traces (sampled) | Merge errors, replication warnings | Insert latency P99, merge queue length |
| **ClickHouse (read)** | Query RPS, query latency (P50/P95/P99), scan rows, MV query ratio | Query traces (all >1s, 1% sampled others) | Slow query log (>500ms), error log | Query latency P95, cache-miss query ratio |
| **Redis Cluster** | Hit rate, miss rate, memory usage, eviction rate, replication lag | N/A (infrastructure) | Connection errors, failover events | Cache hit rate, eviction rate |
| **Query API** | Request RPS, latency (P50/P95/P99), error rate, tenant concurrency | Full request traces (1% sampled) | Error responses, rate-limit triggers | Request latency P95, error rate, 429 rate |
| **Backfill Consumer** | Consumer lag, insert RPS, activation/deactivation events | Batch traces | Activation triggers, errors | Lag recovery rate, processing throughput |

#### SLO Definitions

| SLO | Target | Error Budget (30 days) | Burn-Rate Alert |
|---|---|---|---|
| Dashboard query latency P95 ≤1.5s | 99.5% | 3.6 hours of SLO violation | Alert if >2% budget consumed in 1 hour |
| Ingestion success rate (events acknowledged) | 99.99% | 4.3 minutes of event loss | Alert if >5% budget consumed in 15 minutes |
| Platform uptime (business hours) | 99.9% | 43 minutes downtime | Alert if >10% budget consumed in 1 hour |
| Data freshness (event → dashboard <100 min) | 99.0% | 7.2 hours of freshness violation | Alert if >5% budget consumed in 30 minutes |
| Cache hit rate | 60% (minimum) | N/A (performance optimization) | Alert if <50% over 15-minute window |

#### Alert Routing

| Severity | Criteria | Channel | Response |
|---|---|---|---|
| **P1 — Critical** | SLO burn rate >10× in 5 min; data loss; full-AZ failure | PagerDuty (immediate) | On-call engineer; 15-min acknowledge SLA |
| **P2 — High** | SLO burn rate >2× in 1 hour; single-component failure; consumer lag >60 min | PagerDuty (30 min) + Slack | On-call engineer; 1-hour response SLA |
| **P3 — Warning** | Approaching threshold (capacity >70%, cache hit rate <55%, replica lag >30s) | Slack #ops-alerts | Review next business day |
| **P4 — Info** | Scaling events, deployment completions, maintenance windows | Slack #ops-info | No response required |

Supersedes: none.

## Consequences

- ✅ OpenTelemetry provides vendor-neutral instrumentation — portable across cloud providers and observability backends (RISK-OPS-01).
- ✅ Unified Grafana dashboards correlate metrics, traces, and logs in a single pane, reducing bottleneck detection time to <2 minutes (M-1, RISK-OPS-02).
- ✅ SLO-based alerting with burn-rate thresholds reduces false positive alerts to <5% by alerting on sustained error-budget consumption instead of transient spikes (M-1).
- ✅ Tail-based trace sampling captures all error/slow traces while maintaining ≥1% baseline sampling for healthy requests (M-1).
- ✅ 90-day metrics retention in Mimir satisfies M-1 requirement; traces retained 7 days; logs retained 30 days.
- ✅ Per-component instrumentation table provides a clear implementation checklist, reducing ambiguity during rollout (RISK-OPS-01).
- ⚠️ Grafana Mimir/Tempo/Loki require storage backends (S3/GCS); managed options (Grafana Cloud) trade cost for reduced ops.
- ⚠️ OpenTelemetry Collector DaemonSet adds resource overhead (~100 MB RAM, ~0.1 CPU per node); acceptable at the cluster scale.
- ⚠️ High-cardinality metrics from 1,024 Kafka partitions and per-tenant dimensions require careful label cardinality management to prevent Mimir ingestion costs from escalating.
- ⚠️ Initial SLO definitions and burn-rate thresholds require tuning during the first 30 days of production operation based on observed baseline behavior.
- **Follow-ups:** ADR-0013 (Data Privacy and Compliance Architecture) will define audit log observability. Runbook creation for each P1/P2 alert scenario is a technical debt item to address during implementation.
