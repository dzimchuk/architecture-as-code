# 14. Design Client SDK and Integration Strategy

Date: 2026-02-11

## Status

Proposed

## Context

- **Iteration goal:** Design the client-side tracking SDK (JavaScript and Mobile) that website owners use to integrate analytics event collection, ensuring ≤30 minute integration time, zero server-side changes, <50 KB payload, minimal page load overhead, and consent-aware event dispatch.
- **Business drivers:** The platform's value depends on frictionless tenant adoption. Website owners — often marketers or frontend developers without backend expertise — must integrate tracking with a single script tag. SDK overhead must not degrade the tenant's website performance (Core Web Vitals impact). Events must only be collected when valid consent exists per GDPR/CCPA, with consent state checked locally for sub-millisecond latency.
- **Relevant QAs (IDs):**
  - U-1 — Usability (SDK Integration): integration time ≤30 minutes for basic setup (script tag + domain whitelist); zero server-side infrastructure changes required; SDK payload size <50 KB
  - SE-1 — Security (Data Privacy): consent respected within 1 hour; SDK must honor consent preferences before emitting events
- **Relevant Risks:**
  - RISK-GDPR-01 — Deletion requests cannot complete within 30 days due to distributed data copies; SDK must minimize PII collection and support consent-aware tracking
- **Depends on:** ADR-0005 (Edge Collectors accept HTTPS events), ADR-0013 (Consent Management Service, consent propagation)

### SDK Requirements

| Requirement | Target | Source |
|---|---|---|
| Integration time (basic) | ≤30 minutes | U-1 |
| Server-side changes | Zero | U-1 |
| SDK bundle size | <50 KB (gzip) | U-1 |
| Page load impact | <100 ms total blocking time | Best practice (Core Web Vitals) |
| Consent check | Local, sub-millisecond | SE-1 |
| Event delivery | At-least-once; async, non-blocking | D-1, P-2 |
| Browser support | Latest 2 versions of Chrome, Firefox, Safari, Edge | Industry standard |
| Mobile SDK | iOS (Swift), Android (Kotlin) | Requirements Overview |

## Decision

### Compare SDK Architecture Approaches

| Criterion | A: Full-Featured SDK (Auto-Track Everything) | B: Lightweight Core + Plugin Architecture | C: Tag Manager Proxy (GTM/Segment Wrapper) |
|---|---|---|---|
| **Bundle Size (<50 KB)** | 🟥 Auto-tracking of all DOM events inflates bundle (80–150 KB typical) | 🌟 Core <15 KB; plugins loaded on demand; total <50 KB configurable | 🟨 Depends on tag manager; wrapper adds overhead |
| **Integration Time (≤30 min)** | 🟩 Drop-in script; auto-detects events | 🟩 Script tag + minimal config; plugins added as needed | 🟨 Requires tag manager expertise; additional configuration layer |
| **Page Load Impact** | 🟥 Heavy DOM observation; mutation observers; high TBT | 🌟 Core is async, non-blocking; plugins defer until idle | 🟨 Tag manager adds its own overhead; less control |
| **Consent Awareness** | 🟨 Consent gating at SDK level; but auto-tracking may fire before consent check | 🌟 Core blocks event dispatch until consent validated; plugins respect consent by purpose | 🟨 Consent integration depends on tag manager; less granular control |
| **Extensibility** | 🟨 Monolithic; difficult to customize | 🌟 Plugin API for custom events, enrichment, consent providers | 🟩 Tag manager provides extensibility via its own ecosystem |
| **Vendor Independence** | 🟩 Self-owned SDK; no dependencies | 🟩 Self-owned SDK; no dependencies | 🟥 Tied to tag manager vendor; migration risk |
| **Offline Resilience** | 🟨 Typically no local buffering | 🟩 Core includes localStorage queue for offline/failed sends | 🟥 No offline support in tag managers |
| **Maintenance Burden** | 🟥 Large feature surface; frequent updates for DOM changes | 🟩 Core stable; plugins versioned independently | 🟩 Tag manager vendor handles updates |

### Evaluation Summary

- **Option A** is eliminated — auto-tracking of all DOM events exceeds the 50 KB bundle limit, degrades Core Web Vitals via heavy DOM observation, and risks pre-consent event emission.
- **Option C** introduces vendor dependency on a tag manager with less granular consent control and no guarantee of meeting the 50 KB / 30-minute integration targets.
- **Option B** provides the optimal balance: a minimal core (<15 KB) that handles consent gating, event queuing, and Edge Collector communication, with optional plugins for extended tracking (scroll depth, click maps, UTM parsing).

### Decision

Adopt **Option B: Lightweight Core + Plugin Architecture** for both JavaScript and Mobile SDKs.

#### 1. JavaScript SDK Architecture

```
┌─────────────────────────────────────────────────────┐
│  analytics.js (Core: ~12 KB gzip)                   │
│  ├── Consent Gate (checks local consent state)      │
│  ├── Event Queue (in-memory + localStorage fallback)│
│  ├── Transport (beacon API / fetch to Edge Collector)│
│  ├── Session Manager (first-party cookie, 30-min)   │
│  └── Config (tenant_id, domain whitelist, endpoint) │
├─────────────────────────────────────────────────────┤
│  Plugins (loaded on demand, <5 KB each)             │
│  ├── auto-pageview.js   — automatic page view track │
│  ├── click-tracking.js  — declarative click events  │
│  ├── utm-parser.js      — UTM parameter extraction  │
│  ├── scroll-depth.js    — scroll % tracking         │
│  └── custom-events.js   — developer-defined events  │
└─────────────────────────────────────────────────────┘
```

#### 2. Integration Methods

| Method | Code | Setup Time | Use Case |
|---|---|---|---|
| **Script tag (recommended)** | `<script async src="https://cdn.analytics.example/v1/a.js" data-tenant="TENANT_ID"></script>` | <5 minutes | Standard website; zero server-side changes |
| **NPM package** | `npm install @analytics-platform/sdk` + `import { init } from '@analytics-platform/sdk'` | <15 minutes | SPA (React, Vue, Angular); bundler integration |
| **Mobile SDK (iOS)** | `pod 'AnalyticsPlatformSDK'` or Swift Package Manager | <30 minutes | Native iOS apps |
| **Mobile SDK (Android)** | `implementation 'com.analytics-platform:sdk:1.x'` via Gradle | <30 minutes | Native Android apps |

#### 3. Consent-Aware Event Dispatch

| Step | Behavior |
|---|---|
| 1. SDK loads | Read consent state from first-party cookie (`_ap_consent`) or CMP callback |
| 2. No consent found | SDK enters **silent mode**: no events queued, no network requests |
| 3. Consent granted (by purpose) | SDK activates for consented purposes only; queued events flushed per purpose |
| 4. Consent updated | CMP calls `analytics.updateConsent({analytics: true, marketing: false})`; SDK re-evaluates immediately |
| 5. Consent withdrawn | SDK enters silent mode; local queue cleared; no further events for that purpose |
| 6. Consent refresh | Edge Collectors refresh consent cache every 5 min from Consent Service (ADR-0013) |

- SDK **never** sends events before consent validation — prevents pre-consent data collection.
- Consent purposes: `analytics` (page views, sessions), `marketing` (UTM, attribution), `functional` (feature usage).
- CMP integration via standard callback API: `window.__analytics_consent_callback`.

#### 4. Event Transport Design

| Design Element | Decision | Rationale |
|---|---|---|
| **Primary transport** | `navigator.sendBeacon()` | Non-blocking; survives page unload; ideal for analytics |
| **Fallback transport** | `fetch()` with `keepalive: true` | Broader API support; retry capability |
| **Endpoint** | Regional Edge Collector HTTPS endpoint (ADR-0005) | Nearest region for lowest latency |
| **Batching** | Queue events; flush every 5 seconds or when batch reaches 10 events | Reduces HTTP requests; balances freshness and efficiency |
| **Retry** | 3 retries with exponential backoff (1s, 3s, 9s) | At-least-once delivery |
| **Offline queue** | `localStorage` buffer (max 100 events, ~50 KB); flush on reconnect | Prevents event loss during transient connectivity issues |
| **Payload format** | JSON; fields: `tenant_id`, `session_id`, `event_type`, `timestamp`, `page_url`, `referrer`, `device`, `geo` (IP-resolved server-side), `utm_*`, `custom_properties` | Compact; schema-validated at Edge Collector |
| **Payload size** | ~200–500 bytes per event (uncompressed) | Minimal bandwidth impact per ADR-0002 (~0.5 KB) |

#### 5. Privacy-by-Design Measures

| Measure | Implementation |
|---|---|
| **No PII in payload** | SDK does not collect names, emails, or form inputs by default; only behavioral signals |
| **Visitor ID** | First-party cookie with random UUID; no cross-site tracking; no fingerprinting |
| **IP handling** | Client IP resolved to geolocation at Edge Collector server-side; raw IP not stored in ClickHouse |
| **Cookie scope** | First-party, `SameSite=Lax`, `Secure`; no third-party cookies |
| **Data minimization** | Only configured event types collected; no auto-tracking of form data, keystrokes, or sensitive DOM content |
| **Content Security Policy** | SDK compatible with strict CSP; `connect-src` to Edge Collector domain only |

#### 6. Performance Budget

| Metric | Target | Mechanism |
|---|---|---|
| Total Blocking Time (TBT) | <50 ms contribution | `async` script loading; deferred plugin initialization |
| First Contentful Paint (FCP) | Zero impact | SDK does not render anything; no DOM manipulation |
| Network requests | ≤1 per 5 seconds (batched) | Batch queue; `sendBeacon` is non-blocking |
| Memory footprint | <2 MB | Lightweight core; bounded event queue |
| Bundle size (gzip) | Core: <15 KB; Core + all plugins: <50 KB | Tree-shaking; no heavy dependencies |

Supersedes: none.

## Consequences

- ✅ Script-tag integration achieves <5 minute basic setup — well within the 30-minute target (U-1).
- ✅ Core SDK <15 KB gzip with <50 ms TBT ensures negligible page load impact for tenant websites (U-1).
- ✅ Consent gate as the first checkpoint in the event pipeline prevents any pre-consent data collection (SE-1).
- ✅ Plugin architecture keeps initial bundle small while enabling extensibility for advanced tracking use cases (U-1).
- ✅ Privacy-by-design (no PII, first-party cookie, server-side IP resolution) minimizes compliance surface and simplifies GDPR deletion (SE-1, RISK-GDPR-01).
- ✅ `sendBeacon` + localStorage offline queue provides at-least-once delivery without impacting page responsiveness (D-1, U-1).
- ✅ Zero server-side changes required for basic integration — script tag references CDN-hosted SDK (U-1).
- ⚠️ First-party cookie-based visitor ID does not persist across browsers or devices — no cross-device identity resolution by design (privacy trade-off).
- ⚠️ `localStorage` queue limited to 100 events (~50 KB) — extended offline periods may exceed buffer capacity; events dropped with warning.
- ⚠️ CMP integration requires tenant's CMP to implement the callback API; documentation and testing tools required for smooth adoption.
- ⚠️ Mobile SDKs (iOS/Android) require separate implementation and maintenance effort; should share event schema and transport protocol with JS SDK.
- **Follow-ups:** SDK documentation and developer portal are implementation-phase deliverables. Mobile SDK detailed design may warrant a separate ADR if platform-specific architectural decisions arise.
