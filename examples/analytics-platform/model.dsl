analyticsPlatform = softwareSystem "Analytics Platform" "Ingests, stores, and analyzes website event data at hyperscale." {
    !adrs adrs
    !docs docs/src
}

clientWebsite = softwareSystem "Client Website/Mobile App" "Tenant website or mobile app with embedded tracking SDK."

consentManagementPlatform = softwareSystem "Consent Management Platform" "External CMP providing GDPR/CCPA consent state."

websiteVisitor = person "Website Visitor" "Browses tenant sites and generates trackable events."

analyst = person "Analyst/Marketer" "Views dashboards, runs queries, and exports reports."

websiteOwner = person "Website Owner" "Integrates SDK and configures tracking for their site."

privacyOfficer = person "Privacy Officer" "Manages consent, deletion, and data access requests."

websiteVisitor --https-> clientWebsite "Browses pages and performs actions"
clientWebsite --https-> analyticsPlatform "Sends events via JS/Mobile SDK"
analyst --https-> analyticsPlatform "Views dashboards and queries reports"
websiteOwner --https-> analyticsPlatform "Integrates SDK and configures tracking"
privacyOfficer --https-> analyticsPlatform "Submits GDPR/CCPA requests"
consentManagementPlatform --https-> analyticsPlatform "Sends consent updates"