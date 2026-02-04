---
agent: 'agent'
description: 'ADR Iteration'
---

<instructions>
- Capture exactly **one key decision per ADR**.
- Extract and document:
  * Quality attributes (referenced by ID from the quality tree `10_quality_requirements.adoc`)
  * Architectural tactics addressing these attributes
  * Final design decision
- If tool/technology selection is involved → build a **comparison table**.
- Explicitly link ADRs to **QA IDs** and superseded ADRs.
</instructions>

<inputs>
- Quality Attribute Requirements (QARs) and Quality Attribute Scenarios (QASs) documented in `../10_quality_requirements.adoc`  
- Risks documented in `../11_technical_risks.adoc`
- Existing ADRs in `./**.md`
</inputs>

<constraints>
- Always use **comparison tables** when evaluating options.
- Use rating emojis in tables:
  * 🟥 = weak
  * 🟨 = medium
  * 🟩 = strong
  * 🌟 = excellent (optional)
- Keep explanations concise, neutral, and professional.
- Do not explain ADD methodology inside ADRs — keep it here.
</constraints>

<example>
# 10. Select DB Model and Product for Org Hierarchies, RBAC, and Plans
Date: 2025-09-01

## Status
Proposed

## Context
- Iteration goal: choose a **DB** to store:
    * client organizations with hierarchical departments,
    * users/employees, roles/permissions (RBAC, ABAC where needed),
    * pricing/tariff plans and tenant quotas for a large multi-tenant SaaS.
- Business drivers: correctness and security of access control, strong consistency for billing/entitlements, good developer productivity, and cost efficiency.
- Relevant QAs (IDs):  
  P-1 Throughput (read/write), A-1 Availability, C-1 Cost Efficiency, S-1 Scalability (horizontal), D-1 Developer Productivity, I-1 Integrity & ACID, Sec-1 Fine-grained Access Control, MT-1 Multi-tenancy Isolation.

## Decision
### Compare **Databases** (from the shortlist)

| Database               | Hierarchies       | Relational Ops               | Scalability             | Maintainability   | Security/Access         | Consistency | ACID | Multi-Tenancy     |
|------------------------|-------------------|------------------------------|-------------------------|-------------------|-------------------------|-------------|------|-------------------|
| **PostgreSQL**         | 🟩 via CTEs/ltree | 🌟 (joins, constraints, RLS) | 🟨 vert.+extensions     | 🟩 mature tooling | 🌟 RBAC + RLS/Row-Level | 🌟          | 🌟   | 🟩 schemas + RLS  |
| **CockroachDB**        | 🟩                | 🌟                           | 🟩 horiz., resilient    | 🟨 ops complexity | 🟩 RBAC                 | 🌟          | 🌟   | 🟩 multi-tenant   |
| **Amazon Aurora (PG)** | 🟩                | 🌟                           | 🟩 managed read scaling | 🌟 managed        | 🌟 (AWS IAM + PG)       | 🌟          | 🌟   | 🟩 (schemas + SR) |
| **MongoDB**            | 🟩 (docs)         | 🟨                           | 🟩                      | 🟩                | 🟨                      | 🟨          | 🟨   | 🟨                |
| **Neo4j**              | 🌟                | 🟨                           | 🟨                      | 🟨                | 🟨                      | 🟩          | 🟩   | 🟨                |

**Decision:** Prefer **PostgreSQL** as the primary operational store for org hierarchies, RBAC (RLS), entitlements, and billing—balancing ACID guarantees, fine-grained access control, and developer productivity. Consider **Aurora PostgreSQL** or **CockroachDB** where managed horizontal scale or multi-region resilience is a hard requirement.  
Supersedes: none.

## Consequences
- ✅ Strong integrity for permissions/billing (I-1, Sec-1), clear tenancy isolation via schemas + RLS (MT-1).
- ⚠️ Horizontal write scaling requires sharding/partitioning or a managed/Distributed PG (Aurora read scaling; CockroachDB for multi-region writes).
- Follow-ups: ADRs on sharding strategy, RLS policy design, tenancy keying, and read replica/caching for hot paths.
</example>

<validation>
- Verify ADR includes business drivers, QA IDs, one clear decision.
- Verify **both** comparison tables exist (models → products) and use the emoji scale.
- Verify the chosen option is justified by QA trade-offs and consequences.
</validation>

<output>
Return ONLY ADR text in adr-tools format.  
No explanations. No comments. No introductions.
</output>
