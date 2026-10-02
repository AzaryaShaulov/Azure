# AVD Alerts Matrix

Complete reference for all 16 `AVD-Category-*` scheduled query alerts: thresholds, query sources, and response guidance.

All alerts query the **WVDErrors** table in Log Analytics with a 15-minute lookback window (`ago(15m)`), evaluated every 10 minutes. They fire when one or more matching rows are found (count > 0).

## AVD-Category-AuthenticationIdentity

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated authentication and identity failures in AVD.

|CodeSymbolic|Meaning|
|---|---|
|`PasswordMustChange`|User's password must be changed before sign-in|
|`PasswordExpired`|User's password has expired|
|`InvalidAuthToken`|Authentication token is invalid or expired|
|`InvalidCredentials`|Incorrect username or password|
|`AccountLockedOut`|User account is locked in Active Directory / Entra ID|
|`AccountDisabled`|User account is disabled|
|`LogonFailed`|General logon failure|
|`AuthenticationLogonFailed`|Authentication-layer logon failure|
|`NoAuthenticatingAuthority`|No domain controller or Entra ID endpoint could authenticate the user|
|`LocalSecurityAuthorityError`|LSA error on the session host (local domain join or trust issue)|

---

## AVD-Category-AuthorizationPolicy

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated authorization and logon rights failures in AVD.

|CodeSymbolic|Meaning|
|---|---|
|`ConnectionFailedUserNotAuthorized`|User is not in the host pool's application group assignment|
|`LogonTypeNotGranted`|The required logon type (interactive/remote) is not granted by GPO|
|`NotAuthorizedForLogon`|User lacks "Allow log on through Remote Desktop Services" right|

---

## AVD-Category-ConnectionNetworkGateway

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated AVD client, DNS, reverse connect, and gateway transport failures.

|CodeSymbolic|Meaning|
|---|---|
|`Client`|Client-side RDP connection error (generic)|
|`DnsLookupFailed`|DNS resolution failure for the session host or gateway|
|`GatewayServerNotFound`|AVD gateway endpoint unreachable|
|`ReverseConnectDnsLookupFailed`|Session host cannot resolve DNS for the reverse-connect path|
|`ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed`|Client connected too late â€” reverse connection timed out|

---

## AVD-Category-SessionHostHealthCapacity

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated session host availability and capacity issues.

|CodeSymbolic|Meaning|
|---|---|
|`ConnectionFailedNoHealthyRdshAvailable`|No healthy session hosts available in the host pool|
|`SessionHostResourceNotAvailable`|Session host resource is not responding or unavailable|
|`OutOfMemory`|Session host ran out of memory during connection attempt|

---

## AVD-Category-PersonalDesktopAssignment

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated personal desktop assignment and startup failures.

|CodeSymbolic|Meaning|
|---|---|
|`ConnectionFailedPersonalDesktopFailedToBeStarted`|Personal desktop VM failed to start (deallocated/stopped)|
|`ConnectionFailedNoPreAssignedPersonalDesktopForUser`|User has no personal desktop assigned in the host pool|

---

## AVD-Category-DeviceGraphicsInput

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated input and graphics subsystem failures.

|CodeSymbolic|Meaning|
|---|---|
|`GetInputDeviceHandlesError`|Failed to acquire input device handles on the session host|
|`GraphicsCapsNotReceived`|Graphics capabilities were not received from the client|
|`GraphicsSubsystemFailed`|Graphics subsystem (DX/RemoteFX) failed on the session host|
|`DWMProcessAccessFailure`|Desktop Window Manager process could not be accessed|

---

## AVD-Category-FSLogixProfileStorage

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated FSLogix profile and storage attach/detach/access issues. Matches both explicit `CodeSymbolic` values and message-based patterns.

**CodeSymbolic matches:**

|CodeSymbolic|Meaning|
|---|---|
|`ERROR_SHARING_VIOLATION`|Profile VHD/X is locked by another process or session|
|`UnloadWaitingForUserAction`|FSLogix waiting for user action during profile unload|
|`ERROR_ACCESS_DENIED`|Access denied to profile storage path|
|`ERROR_PATH_NOT_FOUND`|Profile storage path does not exist|
|`ERROR_FILE_NOT_FOUND`|Profile VHD/X file not found|
|`ERROR_BAD_NETPATH`|UNC path to profile storage is invalid|
|`ERROR_BAD_NET_NAME`|Network name for profile share is invalid|
|`ERROR_NETNAME_DELETED`|Network connection to profile storage was dropped|
|`ERROR_DISK_FULL`|Profile storage disk is full|
|`ERROR_LOCK_VIOLATION`|File lock conflict on profile VHD/X|

**Message-based matches** (Source `has 'fslogix'` or Message `has_any`):
`frxsvc`, `frxshell`, `temporary profile`, `default profile`, `profile failed`, `vhd attach`, `vhdx attach`, `container attach`, `container detach`, `odfc`

---

## AVD-Category-UnknownUnclassified

**Severity:** 1 (Error)
**Source Table:** WVDErrors
**Evaluation:** PT10M / PT15M

**Description:** Consolidated unknown or unclassified AVD error symbols for triage. Catches errors where the WVD service could not classify the `CodeSymbolic`.

|CodeSymbolic|Meaning|
|---|---|
|`Unknown CodeSymbolic - review Message for details.`|Unclassified error â€” check the `Message` field for root cause|

---

## AVD-Category-ConnectionFailureRate

**Severity:** 1 (Error)
**Source Table:** WVDConnections
**Evaluation:** PT10M / PT15M

**Description:** Spike in failed connections per host pool. Fires when more than 5 failed connections occur in a 15-minute window.

|Signal|Threshold|
|---|---|
|`State == "Failed"` count per HostPool + UserName|> 5 per window|

**Why this matters:** Users unable to connect is the highest-impact operational signal. Not covered by Perf counters or WVDErrors alone â€” a connection can fail without generating a WVDErrors entry if the failure is at the broker/gateway level.

---

## AVD-Category-DisconnectionSpike

**Severity:** 1 (Error)
**Source Table:** WVDConnections
**Evaluation:** PT10M / PT15M

**Description:** Abnormal disconnection rate across session hosts, indicating infrastructure or network instability. Fires when more than 10 disconnections occur per host+session host pair in 15 minutes.

|Signal|Threshold|
|---|---|
|`State == "Completed"` + `ConnectionType == "Disconnected"` per HostPool + SessionHostName|> 10 per window|

**Why this matters:** Mass disconnects point to gateway, networking, or host pool-level issues that are invisible to per-host Perf counters.

---

## AVD-Category-UnhealthyHosts

**Severity:** 1 (Error)
**Source Table:** WVDAgentHealthStatus
**Evaluation:** PT10M / PT15M

**Description:** Session hosts reporting non-Available status (Unavailable, NeedsAssistance, Shutdown, Upgrading). Uses `arg_max` to get the latest status per host.

|Signal|Threshold|
|---|---|
|Most recent `Status != "Available"` per SessionHostName|Any host|

**Why this matters:** Catches hosts falling out of service entirely. The existing SessionHostHealthCapacity alert only catches WVDErrors entries, not agents silently going unhealthy.

---

## AVD-Category-StaleHeartbeat

**Severity:** 1 (Error)
**Source Table:** WVDAgentHealthStatus
**Evaluation:** PT10M / PT15M

**Description:** Session hosts with stale agent heartbeat (last seen > 5 minutes ago), indicating agent communication failure or zombie hosts.

|Signal|Threshold|
|---|---|
|Most recent `TimeGenerated < ago(5m)` per SessionHostName|> 5 minutes stale|

**Why this matters:** Hosts that stop heartbeating are effectively dead but may still appear in the host pool, consuming capacity slots without serving users.

---

## AVD-Category-BandwidthDrop

**Severity:** 1 (Error)
**Source Table:** WVDConnectionNetworkData (joined with WVDConnections)
**Evaluation:** PT10M / PT15M

**Description:** Per-connection estimated bandwidth drops below threshold. Uses P10 (10th percentile) to catch sustained low bandwidth rather than brief dips.

|Signal|Threshold|
|---|---|
|P10 `EstAvailableBandwidthKBps` per CorrelationId|< 500 KBps|

**Why this matters:** Protocol-agnostic, per-connection metric â€” more accurate than host-level RemoteFX counters. Low bandwidth degrades media quality, file transfers, and clipboard operations.

---

## AVD-Category-RTTPerUser

**Severity:** 1 (Error)
**Source Table:** WVDConnectionNetworkData (joined with WVDConnections)
**Evaluation:** PT10M / PT15M

**Description:** Per-user P95 round-trip time exceeds threshold. Supplements host-level RemoteFX counters with user-attributed latency from the AVD service.

|Signal|Threshold|
|---|---|
|P95 `EstRoundTripTimeInMs` per CorrelationId|> 200 ms|

**Why this matters:** Helps identify which specific users have bad networks, rather than just flagging that "some host has high RTT." Useful for targeted remediation (VPN, location, ISP issues).

---

## AVD-Category-SignInPhaseDelay

**Severity:** 1 (Error)
**Source Table:** WVDCheckpoints
**Evaluation:** PT10M / PT15M

**Description:** Prolonged sign-in phases detected â€” profile load, GPO processing, shell start. More granular than overall sign-in duration, helps pinpoint which phase is slow.

|Signal|Threshold|
|---|---|
|Individual checkpoint duration (`OnConnected`, `ShellReady`, `LoadProfile`, `ApplyGroupPolicy`)|> 15 seconds|

**Why this matters:** A 30-second sign-in might be caused by slow profile load (FSLogix), slow GPO processing, or slow shell startup. This alert identifies the specific bottleneck.

---

## AVD-Category-FrameQualityDegradation

**Severity:** 1 (Error)
**Source Table:** ConnectionGraphicsData *(Preview)*
**Evaluation:** PT10M / PT15M

**Description:** End-to-end frame delay or dropped frames exceeding threshold. Catches graphics pipeline issues invisible to CPU/memory counters.

|Signal|Threshold|
|---|---|
|Avg `EstEndToEndDelayInMs` per CorrelationId|> 300 ms|
|Avg `FramesSkippedPercentage` per CorrelationId|> 15%|

> **Note:** The `ConnectionGraphicsData` table is in **Preview** â€” schema may change before GA. Deploy this alert only in environments with graphics-intensive workloads (CAD, video editing, media).

---

## Alert Configuration Summary

### WVDErrors Alerts (8)

|Alert Name|Category|Error Codes|Severity|
|---|---|---|---|
|AVD-Category-AuthenticationIdentity|Authentication & Identity|10 codes|1 (Error)|
|AVD-Category-AuthorizationPolicy|Authorization & Policy|3 codes|1 (Error)|
|AVD-Category-ConnectionNetworkGateway|Connection & Network|5 codes|1 (Error)|
|AVD-Category-SessionHostHealthCapacity|Host Health & Capacity|3 codes|1 (Error)|
|AVD-Category-PersonalDesktopAssignment|Personal Desktop|2 codes|1 (Error)|
|AVD-Category-DeviceGraphicsInput|Device & Graphics|4 codes|1 (Error)|
|AVD-Category-FSLogixProfileStorage|FSLogix & Storage|10 codes + message patterns|1 (Error)|
|AVD-Category-UnknownUnclassified|Unknown / Triage|1 catch-all pattern|1 (Error)|

### WVD Diagnostic Log Alerts (8)

|Alert Name|Source Table|Signal|Threshold|Severity|
|---|---|---|---|---|
|AVD-Category-ConnectionFailureRate|WVDConnections|Failed connections per pool|> 5 in 15m|1 (Error)|
|AVD-Category-DisconnectionSpike|WVDConnections|Disconnections per host|> 10 in 15m|1 (Error)|
|AVD-Category-UnhealthyHosts|WVDAgentHealthStatus|Non-Available status|Any host|1 (Error)|
|AVD-Category-StaleHeartbeat|WVDAgentHealthStatus|Last heartbeat age|> 5 min stale|1 (Error)|
|AVD-Category-BandwidthDrop|WVDConnectionNetworkData|P10 bandwidth per connection|< 500 KBps|1 (Error)|
|AVD-Category-RTTPerUser|WVDConnectionNetworkData|P95 RTT per user|> 200 ms|1 (Error)|
|AVD-Category-SignInPhaseDelay|WVDCheckpoints|Individual phase duration|> 15 seconds|1 (Error)|
|AVD-Category-FrameQualityDegradation|ConnectionGraphicsData*|Frame delay / drop rate|> 300ms or > 15%|1 (Error)|

## Prerequisites: AVD Diagnostics

### For WVDErrors alerts (original 8)

Enable at minimum the **Error** log category on the host pool:

```powershell
az monitor diagnostic-settings create `
  --resource "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.DesktopVirtualization/hostpools/{pool}" `
  --name "avd-diagnostics" `
  --workspace "{law-resource-id}" `
  --logs '[{"category":"Error","enabled":true}]'
```

### For WVD Diagnostic Log alerts (new 8)

Enable **allLogs** (or the specific categories below) on the host pool:

```powershell
az monitor diagnostic-settings create `
  --resource "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.DesktopVirtualization/hostpools/{pool}" `
  --name "avd-diagnostics-full" `
  --workspace "{law-resource-id}" `
  --logs '[{"categoryGroup":"allLogs","enabled":true}]'
```

Required diagnostic log categories by alert:

|Alert|Required Log Category|
|---|---|
|ConnectionFailureRate, DisconnectionSpike|Connection|
|UnhealthyHosts, StaleHeartbeat|AgentHealthStatus|
|BandwidthDrop, RTTPerUser|NetworkData|
|SignInPhaseDelay|Checkpoint|
|FrameQualityDegradation|ConnectionGraphicsData (Preview)|

## Tuning

- **Severity override:** Pass `-Severity 0` (Critical) or `-Severity 2` (Warning) to `AVD-AzAlerts-Category-Alerts.ps1` to override the default for all alerts.
- **Evaluation cadence:** Default is every 10 minutes with a 15-minute window. These are defined as `$EvalFrequency` and `$WindowSize` in the script.
- **Adding new error codes:** Add `CodeSymbolic` values to the appropriate category's KQL `where` clause in the `$alertDefinitions` array in `AVD-AzAlerts-Category-Alerts.ps1`.
