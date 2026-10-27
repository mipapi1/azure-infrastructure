# KQL for FSLogix operations

Queries for the central Log Analytics workspace. Replace `<host-prefix>` (`sessionHosts.namePrefix`) and `<storage-account>` before running them. The FSLogix operations workbook (`fslogix.operations.workbook`) uses the same queries.

| File | Table | Shows |
|---|---|---|
| `fslogix-errors-by-host.kql` | `Event` | FSLogix errors and warnings per host, 24 h |
| `fslogix-error-messages.kql` | `Event` | Most frequent FSLogix error messages, 7 days |
| `sign-in-duration.kql` | `WVDConnections` | Connection start to connected per user (P50, P95), 7 days |
| `profile-share-operations.kql` | `StorageFileLogs` | Requests, failures, throttling and latency per hour, 24 h |
| `profile-share-auth-failures.kql` | `StorageFileLogs` | 403 responses by caller and authentication type, 24 h |

`StorageFileLogs` exists only for the Azure Files store (file service diagnostic settings). Share capacity is a platform metric (`FileCapacity`, `FileShareCapacityQuota`), shown in the workbook from Azure Monitor metrics rather than the workspace.
