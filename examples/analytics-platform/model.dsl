analyticsPlatform = softwareSystem "Analytics Platform" "Ingests, stores, and analyzes website event data at hyperscale." {
    !adrs adrs
    !docs docs/src
    
    analyticsUi = webApp "Analytics UI" "Dashboard for viewing reports and segmentation." "React"
    queryApi = api "Query API" "Serves analytical queries with caching and governance." "Node.js"
    edgeCollector = api "Edge Collector" "Regional ingestion endpoint with WAL buffering." "Go"
    eventBroker = kafka "Event Broker" "Distributed message queue for event ingestion." "Kafka KRaft"
    eventStore = datastore "Event Store" "Columnar database with tiered storage." "ClickHouse"
    queryCache = cache "Query Cache" "Result cache for repeated queries." "Redis Cluster"
    backfillConsumer = api "Backfill Consumer" "Conditional lag-recovery processor." "Go"
    consentService = api "Consent Service" "Manages visitor consent state." "PostgreSQL + API"
    complianceOrchestrator = api "Compliance Orchestrator" "Tracks GDPR/CCPA deletion lifecycle." "Node.js"
    
    edgeCollector --https-> eventBroker "Produces events to"
    eventBroker --sdk-> eventStore "Consumed by ClickHouse Kafka Engine"
    backfillConsumer --sdk-> eventBroker "Reads from when lag exceeds threshold"
    backfillConsumer --sdk-> eventStore "Writes backfill batches to"
    queryApi --sdk-> queryCache "Checks for cached results"
    queryApi --sdk-> eventStore "Executes queries against read replicas"
    queryApi --sdk-> queryCache "Writes results to"
    analyticsUi --https-> queryApi "Requests dashboard data from"
    consentService --sdk-> eventBroker "Publishes consent updates to"
    complianceOrchestrator --sdk-> eventBroker "Publishes deletion requests to"
    complianceOrchestrator --sdk-> eventStore "Executes DELETE mutations on"
    complianceOrchestrator --sdk-> queryCache "Invalidates entries in"
}

clientWebsite = softwareSystem "Client Website/Mobile App" "Tenant website or mobile app with embedded tracking SDK."

consentManagementPlatform = softwareSystem "Consent Management Platform" "External CMP providing GDPR/CCPA consent state."

websiteVisitor = person "Website Visitor" "Browses tenant sites and generates trackable events."

analyst = person "Analyst/Marketer" "Views dashboards, runs queries, and exports reports."

websiteOwner = person "Website Owner" "Integrates SDK and configures tracking for their site."

privacyOfficer = person "Privacy Officer" "Manages consent, deletion, and data access requests."

websiteVisitor --https-> clientWebsite "Browses pages and performs actions"
clientWebsite --https-> analyticsPlatform.edgeCollector "Sends events via JS/Mobile SDK"
analyst --https-> analyticsPlatform.analyticsUi "Views dashboards and queries reports"
websiteOwner --https-> analyticsPlatform.analyticsUi "Integrates SDK and configures tracking"
privacyOfficer --https-> analyticsPlatform.complianceOrchestrator "Submits GDPR/CCPA requests"
consentManagementPlatform --https-> analyticsPlatform.consentService "Sends consent updates"