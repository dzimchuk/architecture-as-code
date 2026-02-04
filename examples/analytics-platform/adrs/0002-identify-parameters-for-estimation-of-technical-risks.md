# 2. Identify Parameters for Estimation of Technical Risks

Date: 2026-02-04

## Status

Proposed

## Context

The Analytics Platform must handle massive scale event tracking from websites while providing fast query responses. Before performing detailed sizing estimates and risk analysis, we need to identify and document all key assumptions and system parameters that will drive our back-of-the-envelope calculations.

### Key Assumptions

| Assumption | Value | Source |
|------------|-------|--------|
| Initial daily events | 100 billion events/day | Requirements Overview |
| Annual growth rate | +10% year-over-year | Industry standard for growing platforms |
| Peak traffic multiplier | ×3 | Common peak-to-average ratio for web analytics |
| Number of analytics users | 100,000 initial users | Requirements Overview |
| Average event size | ~0.5 KB | Typical web analytics event payload |
| Data retention | Forever | Quality Goals |
| Ingestion delay tolerance | 50–100 minutes | Quality Goals |

### Referenced Quality Attribute Requirements

| QAR ID | Quality Attribute | Threshold | Context |
|--------|-------------------|-----------|---------|
| QAR-1 | Performance (Latency) | Reports/charts delivered within 1.5 seconds | For any parameter combination over ≤3 months |
| QAR-2 | Scalability (Throughput) | ~100 billion events per day | System ingestion capacity |
| QAR-3 | Availability (Freshness) | 50–100 minute delay acceptable | Between user action and statistics appearance |
| QAR-4 | Data Durability | Forever retention | Per-website data storage requirement |

## Decision

We will establish baseline parameters for the following system dimensions to support later back-of-the-envelope calculations:

### Scale Parameters
- **Daily Active Users**: Website visitors generating events
- **Events per Day**: Total event volume requiring ingestion and storage
- **Events per Year**: Annual cumulative volume
- **Growth Projections**: 5-year forward projections with 10% YoY growth

### Storage Parameters
- **Event Database Size**: Raw event storage requirements (TB)
- **Event Size**: Average bytes per event
- **Storage Growth Rate**: Annual storage accumulation

### Throughput Parameters
- **Write RPS** (Requests Per Second): Average event ingestion rate
- **Peak Write RPS**: Maximum ingestion rate during traffic spikes
- **Read RPS** (Real-Time): Query rate for live dashboards
- **Peak Read RPS** (Real-Time): Maximum query rate during peak usage
- **Aggregated Read RPS**: Query rate for historical reports
- **Peak Aggregated Read RPS**: Maximum historical query rate

### Network Parameters
- **Write Network Bandwidth**: Ingestion bandwidth (GB/s)
- **Read Network Bandwidth**: Query response bandwidth (GB/s)
- **Total Network Bandwidth**: Combined read/write bandwidth

### User Parameters
- **Number of Analytics Users**: Concurrent users accessing reports
- **Queries per User**: Average query frequency per user session

These parameters will be estimated across a 5-year projection to identify technical risks and infrastructure requirements.

## Consequences

### Positive
- Clear parameter baseline enables structured capacity planning
- Explicit assumptions make estimation methodology transparent and auditable
- Quality attribute mapping ensures calculations address actual business requirements
- 5-year projection provides long-term infrastructure planning visibility

### Negative
- Parameters are based on assumptions that may not reflect actual usage patterns
- Growth rate projections introduce uncertainty in later years
- Missing parameters may emerge during detailed design requiring re-estimation

### Follow-up Actions
- Perform back-of-the-envelope calculations for each identified parameter
- Create projection tables showing 5-year capacity requirements
- Analyze technical risks based on calculated throughput and storage needs
- Identify infrastructure bottlenecks and mitigation strategies
- Document findings in subsequent ADRs (ADR-0003 for calculations, ADR-0004 for risk analysis)
