# Provisioning parameters for multistage VM provisioning

This document defines the configuration values used by the VM provisioning pipeline. The event payload is passed from the form through several stages, and each stage may enrich the event with runtime values that were created later in the pipeline (for example network details).

The parameters are split into two groups:

- Static configuration: values that are shared across a provisioning request or deployment pattern.
- Per-VM configuration: values that vary per server instance or per request line item.

## 1. Static configuration

These values are usually defined at the platform, application, or request level and do not change for each provisioned VM unless a new request is created.

```json
{
  "eventType": "deployServer",
  "requestId": "req-contract-lifecycle-manager-20260609",
  "requestDate": "2026-06-09",
  "requestor": "test.requestor@demo.local",
  "application": {
    "name": "Contract Lifecycle Manager",
    "shortName": "contract-lifecycle-manager",
    "description": "Server order request for Contract Lifecycle Manager",
    "projectNumber": "PRJ-017",
    "tenancyModel": "sharedDatacenter",
    "sharedDatacenter": "corp-weu-shared-01"
  },
  "serviceLevel": "bronze",
  "funding": {
    "projectFunded": "no",
    "projectId": "",
    "costCenterId": "cc001",
    "companyCode": "FI01"
  },
  "pricing": {
    "monthlyEstimateEur": 506.76
  },
  "azure": {
    "tenantId": "00000000-0000-0000-0000-000000000000",
    "subscriptionId": "5bd43c18-36c0-46d7-9b22-cf8b03a1c756",
    "location": "westeurope"
  },
  "server": {
    "type": "database-server",
    "environment": "dev",
    "deployModel": "paas",
    "dbEngine": "Azure SQL Database",
    "dbInstance": "instance1",
    "collation": "Latin1_General_CI_AS",
    "paasTier": "general-purpose",
    "paasStorage": 16,
    "paasVCores": 2
  }
}
```

### Static parameter list

- Request metadata
  - `eventType`
  - `requestId`
  - `requestDate`
  - `requestor`
  - `source`
  - `processedAt`
  - `messageId`

- Application / business metadata
  - `application.name`
  - `application.shortName`
  - `application.description`
  - `application.projectNumber`
  - `application.tenancyModel`
  - `application.sharedDatacenter`

- Service and cost metadata
  - `serviceLevel`
  - `funding.projectFunded`
  - `funding.projectId`
  - `funding.costCenterId`
  - `funding.companyCode`
  - `pricing.monthlyEstimateEur`

- Azure / environment context
  - `azure.tenantId`
  - `azure.subscriptionId`
  - `azure.location`

- Server pattern defaults
  - `server.type`
  - `server.deployModel` (for example `paas` or `iaas`)
  - `server.dbEngine` (initially `Azure SQL Database`)
  - `server.collation`
  - `server.paasTier`
  - `server.paasStorage`
  - `server.paasVCores`
  - `server.os` and `server.osVersion` if the same for all VMs in a request

Notes:

- `dbEngine` should be nullable or optional for servers without an RDBMS. When no database is required, the pipeline can omit `dbEngine`, `dbInstance`, `collation`, and the PaaS storage / vcore values.
- Values that are defined once per request are static even if the requester is provisioning multiple VMs; they remain the same for all server instances in that request unless another explicit decision is made.

## 2. Per-VM configuration

These values vary for each provisioned VM instance, and they need to be evaluated per server or per line item.

```json
{
  "order": {
    "serverCount": 1,
    "lineItemIndex": 1
  },
  "server": {
    "environment": "dev",
    "vmSize": "Standard_D4s_v5",
    "os": "Windows",
    "osVersion": "2022-Datacenter",
    "osDiskSizeGb": 128,
    "instanceIndex": 1,
    "dbInstance": "instance1",
    "network": {
      "subnetResourceId": "/subscriptions/.../subnets/snet-contract-lifecycle-manager-dev",
      "nsgId": "",
      "cidr": "10.1.1.16/28"
    }
  }
}
```

### Per-VM parameter list

- Order / instance metadata
  - `order.serverCount`
  - `order.lineItemIndex`
  - `server.instanceIndex`

- VM sizing and operating system
  - `server.vmSize`
  - `server.os`
  - `server.osVersion`
  - `server.osDiskSizeGb`

- Environment and naming
  - `server.environment`
  - `server.name` or generated VM name
  - `server.hostName` or generated hostname

- Database configuration when applicable
  - `server.dbEngine`
  - `server.dbInstance`
  - `server.collation`
  - `server.paasTier`
  - `server.paasStorage`
  - `server.paasVCores`
  - `server.rdsInstanceClass` or equivalent if the platform later adds non-SQL RDBMS support

- Network configuration produced by later pipeline stages
  - `network.subnetResourceId`
  - `network.nsgId`
  - `network.cidr`
  - `network.privateIp`
  - `network.publicIpId`
  - `network.nicId`

- Additional runtime metadata produced after provisioning
  - `vmResourceId`
  - `vmName`
  - `vmPrivateIp`
  - `vmPublicIp`
  - `provisionedAt`
  - `status`

## 3. Recommended event structure

The event should represent two layers:

1. Request-scoped configuration: values used for all server instances in the request.
2. Instance-scoped configuration: values specific to a single VM, including runtime information added by later stages.

A practical shape is:

```json
{
  "eventType": "deployServer",
  "requestId": "...",
  "requestDate": "...",
  "requestor": "...",
  "application": { "...": "..." },
  "serviceLevel": "...",
  "funding": { "...": "..." },
  "azure": { "...": "..." },
  "globalSettings": {
    "deployModel": "paas",
    "dbEngine": "Azure SQL Database",
    "os": "Windows",
    "osVersion": "2022-Datacenter"
  },
  "servers": [
    {
      "instanceIndex": 1,
      "environment": "dev",
      "vmSize": "Standard_D4s_v5",
      "osDiskSizeGb": 128,
      "dbInstance": "instance1",
      "network": {
        "subnetResourceId": "...",
        "cidr": "10.1.1.16/28"
      }
    }
  ]
}
```

This keeps request-level settings separate from VM-level values and makes the multistage pipeline easier to process without overwriting earlier data.

## 4. Decision rules

- If a value is the same for all VMs in the request, keep it at the request/global level.
- If a value changes per VM, keep it in the `servers[]` item.
- If a stage creates new infrastructure details, append them to the VM item rather than mutating the original request-level defaults.
- If a server does not need an RDBMS, set `dbEngine` and related database fields to `null` or omit them entirely.
- The RDBMS default should be Microsoft SQL Server / Azure SQL Database, but the pipeline should remain extensible for other database engines in the future.

## 5. Summary

The main separation is:

- Static configuration = platform, request, and environment defaults that stay fixed for the deployment request.
- Per-VM configuration = server-specific values, sizing, networking, and database selections that differ per instance.

The pipeline should preserve both layers in the event file and allow later stages to append generated values such as subnet, NIC, IP, and resource IDs without losing the original request parameters.
