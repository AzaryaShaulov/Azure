# AVD Alerts — Operational Runbook

Procedures for responding to `AVD-Category-*` alerts. All alerts fire from the **WVDErrors** table in Log Analytics when one or more matching error events occur within a 15-minute window.

---

## AVD-Category-AuthenticationIdentity

**Signal:** Authentication or identity failures detected in WVDErrors.

**Impact:** Users cannot sign in to AVD sessions. May affect individual users (password issues) or all users (domain/Entra ID outage).

### Triage Steps

1. **Identify scope** — is this one user or many?
   ```kql
   WVDErrors
   | where TimeGenerated > ago(1h)
   | where CodeSymbolic in ('PasswordMustChange','PasswordExpired','InvalidAuthToken','InvalidCredentials','AccountLockedOut','AccountDisabled','LogonFailed','AuthenticationLogonFailed','NoAuthenticatingAuthority','LocalSecurityAuthorityError')
   | summarize Count=count() by UserName, CodeSymbolic
   | order by Count desc
   ```
2. **PasswordExpired / PasswordMustChange** — check user's password status in Entra ID or AD
3. **AccountLockedOut** — check AD lockout status and identify the source (brute force, cached credentials on another device)
4. **InvalidAuthToken** — check if Entra ID token issuance is healthy; may indicate a stale SSO session
5. **NoAuthenticatingAuthority / LocalSecurityAuthorityError** — check AD DS / domain controller health on session hosts; verify AD site and subnet configuration

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| PasswordExpired / PasswordMustChange | User must reset password via SSPR or helpdesk |
| AccountLockedOut | Unlock account in AD; investigate lockout source |
| AccountDisabled | Re-enable account if appropriate |
| InvalidCredentials | User entering wrong password — verify UPN format |
| InvalidAuthToken | Clear browser/client cache; re-authenticate |
| NoAuthenticatingAuthority | Verify DC connectivity from session hosts; check DNS resolution for domain |
| LocalSecurityAuthorityError | Check session host domain join status; verify secure channel (`Test-ComputerSecureChannel`) |

---

## AVD-Category-AuthorizationPolicy

**Signal:** Users authenticated successfully but lack permission to connect.

**Impact:** Users see "You are not authorized" when attempting to connect. Can affect individual users (missing app group assignment) or groups (GPO misconfiguration).

### Triage Steps

1. **ConnectionFailedUserNotAuthorized** — check if the user is assigned to the host pool's application group
   ```powershell
   az desktopvirtualization workspace show -g {rg} -n {workspace} --query "applicationGroupReferences"
   ```
2. **LogonTypeNotGranted / NotAuthorizedForLogon** — check Group Policy on session hosts:
   - `Computer Configuration > Windows Settings > Security Settings > Local Policies > User Rights Assignment`
   - Verify "Allow log on through Remote Desktop Services" includes the appropriate user groups

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| ConnectionFailedUserNotAuthorized | Add user/group to the application group: `az desktopvirtualization application-group update ...` |
| LogonTypeNotGranted | Update GPO to grant "Allow log on through Remote Desktop Services" to the Remote Desktop Users group |
| NotAuthorizedForLogon | Same as above; also check "Deny log on through Remote Desktop Services" for conflicting entries |

---

## AVD-Category-ConnectionNetworkGateway

**Signal:** Network, DNS, or gateway transport failures preventing RDP connections.

**Impact:** Users cannot establish RDP sessions. May indicate network-wide issues (DNS, gateway outage) or isolated client problems.

### Triage Steps

1. **Identify scope** — check if failures are from specific clients, session hosts, or widespread:
   ```kql
   WVDErrors
   | where TimeGenerated > ago(1h)
   | where CodeSymbolic in ('Client','DnsLookupFailed','GatewayServerNotFound','ReverseConnectDnsLookupFailed','ConnectionFailedClientConnectedTooLateReverseConnectionAlreadyClosed')
   | summarize Count=count() by CodeSymbolic, _ResourceId
   | order by Count desc
   ```
2. **DnsLookupFailed / ReverseConnectDnsLookupFailed** — check DNS configuration on session hosts and in the VNet
3. **GatewayServerNotFound** — check Azure service health for the AVD gateway in your region
4. **Client** — check client-side network (VPN, proxy, firewall blocking RDP)
5. **ReverseConnectionAlreadyClosed** — the reverse-connect channel timed out before the client connected; often caused by high latency or slow client response

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| DnsLookupFailed | Fix DNS settings on session host VNet; verify DNS forwarders |
| ReverseConnectDnsLookupFailed | Verify session hosts can resolve `*.wvd.microsoft.com` |
| GatewayServerNotFound | Check [Azure Status](https://status.azure.com) for AVD gateway health; try another region if available |
| Client | Client-side issue — update RDP client, check firewall/proxy rules, verify outbound 443 is open |
| ConnectionFailedClientConnectedTooLate... | Investigate client network latency; consider RDP Shortpath for lower latency |

---

## AVD-Category-SessionHostHealthCapacity

**Signal:** No healthy session hosts available or host resource exhaustion.

**Impact:** Users cannot connect at all. This is a **critical** alert — the host pool has no capacity to serve connections.

### Triage Steps

1. **Check host pool health:**
   ```kql
   WVDAgentHealthStatus
   | where TimeGenerated > ago(30m)
   | summarize arg_max(TimeGenerated, *) by SessionHostName
   | project SessionHostName, Status=HealthStatus, LastHeartbeat=TimeGenerated, ActiveSessions
   | order by Status asc
   ```
2. **ConnectionFailedNoHealthyRdshAvailable** — all session hosts are either unavailable, in drain mode, or at max capacity
3. **SessionHostResourceNotAvailable** — specific session host is not responding to the AVD agent
4. **OutOfMemory** — session host ran out of memory during connection processing

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| ConnectionFailedNoHealthyRdshAvailable | Immediately check: (1) Are hosts powered on? (2) Are hosts in drain mode? (3) Are hosts at max session limit? Scale out or remove drain mode. |
| SessionHostResourceNotAvailable | Restart the affected session host; check Azure VM health; verify AVD agent service is running (`RDAgent`, `RDAgentBootLoader`) |
| OutOfMemory | Restart the host to reclaim memory; reduce max sessions; increase VM size |

**Escalation:** If all hosts are unhealthy, check for infrastructure issues: Azure region health, VNet connectivity, domain join status.

---

## AVD-Category-PersonalDesktopAssignment

**Signal:** Personal desktop VMs failed to start or user has no assigned desktop.

**Impact:** Users with personal desktops cannot connect. Typically affects individual users.

### Triage Steps

1. **ConnectionFailedPersonalDesktopFailedToBeStarted** — check if the VM is deallocated and whether Start VM on Connect is enabled:
   ```powershell
   az vm show -g {rg} -n {vm-name} --query "powerState"
   ```
2. **ConnectionFailedNoPreAssignedPersonalDesktopForUser** — check the host pool for user assignment:
   ```powershell
   az desktopvirtualization session-host list -g {rg} --host-pool-name {pool} --query "[].{Host:name, AssignedUser:assignedUser}"
   ```

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| ConnectionFailedPersonalDesktopFailedToBeStarted | Manually start the VM; verify Start VM on Connect is enabled on the host pool; check the VM for boot diagnostics errors |
| ConnectionFailedNoPreAssignedPersonalDesktopForUser | Assign a personal desktop to the user via Azure Portal or CLI; check if the user was recently removed from assignment |

---

## AVD-Category-DeviceGraphicsInput

**Signal:** Input device or graphics subsystem failures on session hosts.

**Impact:** Users may see black screens, frozen displays, or input not working. Typically host-specific.

### Triage Steps

1. **GetInputDeviceHandlesError** — check if input redirection GPOs are blocking device handles
2. **GraphicsCapsNotReceived** — RDP client did not send graphics capabilities; check client version
3. **GraphicsSubsystemFailed** — GPU driver crash or RemoteFX failure on the session host
4. **DWMProcessAccessFailure** — Desktop Window Manager is not running or cannot be accessed

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| GetInputDeviceHandlesError | Review GPO for input device redirection settings; restart the session host |
| GraphicsCapsNotReceived | Update the RDP client; check if the client supports the required graphics mode |
| GraphicsSubsystemFailed | Update GPU drivers (NVIDIA GRID for NV-series); restart the session host; check Event Viewer for DxgKrnl errors |
| DWMProcessAccessFailure | Restart the DWM service or reboot the session host; verify the Desktop experience feature is installed |

---

## AVD-Category-FSLogixProfileStorage

**Signal:** FSLogix profile container attach, detach, or storage access failures.

**Impact:** Users sign in with temporary or default profiles, losing personalization, app settings, and potentially data. **High user impact.**

### Triage Steps

1. **Identify affected users and error pattern:**
   ```kql
   WVDErrors
   | where TimeGenerated > ago(1h)
   | where CodeSymbolic in ('ERROR_SHARING_VIOLATION','ERROR_ACCESS_DENIED','ERROR_PATH_NOT_FOUND','ERROR_FILE_NOT_FOUND','ERROR_BAD_NETPATH','ERROR_BAD_NET_NAME','ERROR_NETNAME_DELETED','ERROR_DISK_FULL','ERROR_LOCK_VIOLATION','UnloadWaitingForUserAction')
      or Source has 'fslogix'
      or Message has_any ('frxsvc','frxshell','temporary profile','default profile','profile failed','vhd attach','vhdx attach','container attach','container detach','odfc')
   | summarize Count=count() by UserName, CodeSymbolic, Source
   | order by Count desc
   ```
2. **ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION** — VHD is locked by another session (orphaned session on a different host)
3. **ERROR_ACCESS_DENIED** — NTFS or share permissions on the profile storage are incorrect
4. **ERROR_PATH_NOT_FOUND / ERROR_BAD_NETPATH / ERROR_BAD_NET_NAME** — storage path is wrong or unreachable
5. **ERROR_DISK_FULL** — profile storage is full
6. **ERROR_NETNAME_DELETED** — SMB connection to storage was dropped (transient network issue)
7. **Message-based matches** (temporary profile, container attach) — FSLogix fell back to a temporary profile

### Resolution

| CodeSymbolic | Resolution |
|---|---|
| ERROR_SHARING_VIOLATION | Find and log off the orphaned session on the other host; enable FSLogix `DeleteLocalProfileWhenVHDShouldApply` |
| ERROR_LOCK_VIOLATION | Same as sharing violation; check for backup software locking the VHD |
| ERROR_ACCESS_DENIED | Fix NTFS permissions on the profile share (`Users: Modify` on their folder); fix share permissions |
| ERROR_PATH_NOT_FOUND | Verify FSLogix `VHDLocations` registry key points to the correct UNC path |
| ERROR_FILE_NOT_FOUND | The user's VHD/X was deleted or moved; recreate or restore from backup |
| ERROR_BAD_NETPATH / ERROR_BAD_NET_NAME | Verify DNS resolution to file share; check private endpoint if using Azure Files |
| ERROR_NETNAME_DELETED | Transient network drop — monitor for recurrence; check NSG/firewall rules |
| ERROR_DISK_FULL | Expand storage quota; clean up old/orphaned profiles; implement profile size limits |
| UnloadWaitingForUserAction | Check for applications holding handles open during sign-out; review FSLogix `frxsvc` logs |
| Message: temporary profile | Root cause is one of the above — use the `Message` field to identify which |

**Storage-specific checks:**
- **Azure Files:** Check quota, private endpoint connectivity, firewall rules, NTFS permissions
- **Azure NetApp Files:** Check volume capacity, export policy, mount permissions
- **File server:** Check disk space, share permissions, SMB connectivity

---

## AVD-Category-UnknownUnclassified

**Signal:** WVDErrors with unclassified `CodeSymbolic` values.

**Impact:** Varies — these are errors the AVD service could not categorize. Requires manual investigation of the `Message` field.

### Triage Steps

1. **Query for details:**
   ```kql
   WVDErrors
   | where TimeGenerated > ago(1h)
   | where CodeSymbolic == "Unknown CodeSymbolic - review Message for details."
   | project TimeGenerated, UserName, Source, Message, Operation, _ResourceId
   | order by TimeGenerated desc
   ```
2. Read the `Message` field — it typically contains the actual error description
3. Check the `Source` field to identify which AVD component generated the error
4. Check the `Operation` field for the failed operation context

### Resolution

- Investigate case-by-case based on the `Message` content
- If a pattern emerges (same message repeatedly), consider adding a new category alert for that specific error
- Common unclassified errors include transient service issues, edge-case timeout scenarios, and new error types not yet categorized by the AVD service
- If persistent and unclear, open a support case with Microsoft referencing the `Message` and `Operation` values

---

## AVD-Category-ConnectionFailureRate

**Signal:** More than 5 failed connections per host pool in 15 minutes (WVDConnections).

**Impact:** Users cannot connect to AVD sessions. A spike in failures may indicate broker, gateway, or host pool-level issues.

### Triage Steps

1. **Identify scope — which host pool and which users:**
   ```kql
   WVDConnections
   | where TimeGenerated > ago(1h)
   | where State == "Failed"
   | extend HostPool = tostring(split(_ResourceId, '/')[-1])
   | summarize FailedCount = count() by HostPool, UserName, SessionHostName
   | order by FailedCount desc
   ```
2. Check the `FailureReason` field for specific error details
3. If failures are across all users: check host pool health, gateway service status
4. If failures are for specific users: check their authorization (app group assignment), credentials

### Resolution

| Pattern | Resolution |
|---|---|
| All users failing | Check host pool health (UnhealthyHosts alert may also fire); verify AVD gateway health at [Azure Status](https://status.azure.com) |
| Specific users failing | Check app group assignment, account status, credential issues |
| Specific session hosts | Restart affected hosts; check RDAgent service |
| Burst after maintenance | Verify hosts are out of drain mode and have started successfully |

---

## AVD-Category-DisconnectionSpike

**Signal:** More than 10 disconnections per session host in 15 minutes (WVDConnections).

**Impact:** Users are being disconnected from active sessions. Mass disconnects indicate infrastructure instability.

### Triage Steps

1. **Identify affected hosts and users:**
   ```kql
   WVDConnections
   | where TimeGenerated > ago(1h)
   | where State == "Completed"
   | where ConnectionType == "Disconnected"
   | extend HostPool = tostring(split(_ResourceId, '/')[-1])
   | summarize DisconnectCount = count() by HostPool, SessionHostName, bin(TimeGenerated, 5m)
   | order by DisconnectCount desc
   ```
2. If disconnections cluster on specific hosts: check host health, memory, network
3. If disconnections are pool-wide: check gateway, VNet connectivity, NSG rules
4. Check if a maintenance window or autoscale drain event coincides

### Resolution

| Pattern | Resolution |
|---|---|
| Single host, many disconnects | Restart the session host; check event logs for crashes |
| Pool-wide spike | Check Azure region health, VNet/NSG changes, gateway connectivity |
| Correlated with autoscale | Review autoscale drain behavior — sessions may be logoff-forced |
| Client-side pattern | Check specific client networks (VPN, proxy, firewall) |

---

## AVD-Category-UnhealthyHosts

**Signal:** Session hosts with `Status != "Available"` in WVDAgentHealthStatus.

**Impact:** Hosts are out of service — they will not accept new connections. Reduces pool capacity.

### Triage Steps

1. **Identify unhealthy hosts and their status:**
   ```kql
   WVDAgentHealthStatus
   | where TimeGenerated > ago(30m)
   | summarize arg_max(TimeGenerated, *) by SessionHostName
   | where Status != "Available"
   | extend HostPool = tostring(split(_ResourceId, '/')[-1])
   | project HostPool, SessionHostName, Status, LastHeartBeat = TimeGenerated, ActiveSessions
   | order by Status asc
   ```
2. Check the `Status` value:
   - **Unavailable**: Host is off, unreachable, or agent crashed
   - **NeedsAssistance**: Agent is running but cannot serve sessions (check domain join, RD services)
   - **Shutdown**: Host is deallocated or shutting down
   - **Upgrading**: AVD agent is being updated
3. Verify the VM is powered on in Azure Portal
4. Check `RDAgent` and `RDAgentBootLoader` services on the host

### Resolution

| Status | Resolution |
|---|---|
| Unavailable | Start the VM; check boot diagnostics; restart RDAgent service |
| NeedsAssistance | Check domain join (`dsregcmd /status`); verify RD licensing; check time sync |
| Shutdown | Start the VM if autoscale is not managing it; check Start VM on Connect |
| Upgrading | Wait for upgrade to complete; if stuck > 30 min, restart the VM |

---

## AVD-Category-StaleHeartbeat

**Signal:** Session hosts whose last heartbeat is older than 5 minutes (WVDAgentHealthStatus).

**Impact:** The host may appear in the pool but is effectively dead. Users may be routed to it and fail to connect.

### Triage Steps

1. **Identify stale hosts:**
   ```kql
   WVDAgentHealthStatus
   | summarize arg_max(TimeGenerated, *) by SessionHostName
   | where TimeGenerated < ago(5m)
   | extend HostPool = tostring(split(_ResourceId, '/')[-1])
   | extend StaleSinceMin = datetime_diff('minute', now(), TimeGenerated)
   | project HostPool, SessionHostName, Status, StaleSinceMin
   | order by StaleSinceMin desc
   ```
2. Check if the VM is running in Azure Portal
3. RDP or Bastion to the host and check if `RDAgentBootLoader` service is running
4. Check if there are network connectivity issues (NSG, firewall, DNS)

### Resolution

| Pattern | Resolution |
|---|---|
| VM is deallocated | Expected if autoscale powered it down; remove from monitoring scope |
| VM is running but no heartbeat | Restart `RDAgentBootLoader` service; if that fails, restart VM |
| Multiple hosts stale | Check VNet DNS, NSG outbound rules — could be network-wide issue |
| Agent crash loop | Re-install the AVD agent on the host |

---

## AVD-Category-BandwidthDrop

**Signal:** P10 estimated bandwidth < 500 KBps per connection (WVDConnectionNetworkData).

**Impact:** Low bandwidth degrades media quality, file transfers, clipboard operations. Users experience freezes and poor responsiveness.

### Triage Steps

1. **Identify affected users and sessions:**
   ```kql
   WVDConnectionNetworkData
   | where TimeGenerated > ago(1h)
   | summarize P10BW = percentile(EstAvailableBandwidthKBps, 10), AvgBW = avg(EstAvailableBandwidthKBps) by CorrelationId
   | where P10BW < 500
   | join kind=inner (WVDConnections | where TimeGenerated > ago(1h) | project CorrelationId, UserName, SessionHostName) on CorrelationId
   | project UserName, SessionHostName, P10BW_KBps = round(P10BW, 0), AvgBW_KBps = round(AvgBW, 0)
   | order by P10BW_KBps asc
   ```
2. Check if affected users are on VPN, remote locations, or specific ISPs
3. Check if RDP Shortpath (UDP) is being used or falling back to TCP
4. Review if bandwidth issues correlate with high RTT (RTTPerUser alert)

### Resolution

| Pattern | Resolution |
|---|---|
| Specific users / locations | Client-side network issue — work with user to check ISP, VPN, Wi-Fi |
| VPN users | Configure split-tunneling for AVD traffic |
| Pool-wide bandwidth drop | Check Azure region network health; review ExpressRoute / VPN gateway throughput |
| TCP fallback | Enable RDP Shortpath for improved throughput |

---

## AVD-Category-RTTPerUser

**Signal:** P95 round-trip time > 200 ms per user connection (WVDConnectionNetworkData).

**Impact:** Users experience visual lag, input delay, and poor session responsiveness. Higher severity than host-level RTT because it's user-attributed.

### Triage Steps

1. **Identify high-RTT users:**
   ```kql
   WVDConnectionNetworkData
   | where TimeGenerated > ago(1h)
   | summarize P95RTT = percentile(EstRoundTripTimeInMs, 95), AvgRTT = avg(EstRoundTripTimeInMs) by CorrelationId
   | where P95RTT > 200
   | join kind=inner (WVDConnections | where TimeGenerated > ago(1h) | project CorrelationId, UserName, SessionHostName) on CorrelationId
   | project UserName, SessionHostName, P95RTT_ms = round(P95RTT, 0), AvgRTT_ms = round(AvgRTT, 0)
   | order by P95RTT_ms desc
   ```
2. Check user location — remote users naturally have higher RTT
3. Check if VPN, proxy, or geographic distance is the cause
4. Compare with BandwidthDrop alert — low bandwidth often accompanies high RTT

### Resolution

| Pattern | Resolution |
|---|---|
| Remote / international users | Consider deploying session hosts closer to the user (multi-region host pools) |
| VPN users | Configure split-tunneling for AVD traffic to reduce VPN overhead |
| Intermittent spikes | Check for network congestion at specific times; review QoS policies |
| All users high RTT | Check Azure region health; review ExpressRoute / WAN connectivity |

---

## AVD-Category-SignInPhaseDelay

**Signal:** Individual sign-in phase takes longer than 15 seconds (WVDCheckpoints).

**Impact:** Slow sign-in degrades the user experience. This alert identifies the specific bottleneck phase.

### Triage Steps

1. **Identify slow phases:**
   ```kql
   WVDCheckpoints
   | where TimeGenerated > ago(1h)
   | where Source == "WVDConnections"
   | where Name in ("OnConnected", "ShellReady", "LoadProfile", "ApplyGroupPolicy")
   | extend HostPool = tostring(split(_ResourceId, '/')[-1])
   | extend DurationSec = datetime_diff('second', TimeGenerated, todatetime(tostring(Parameters.StartTime)))
   | where DurationSec > 15
   | project HostPool, UserName, Name, DurationSec, SessionHostName = tostring(Parameters.SessionHostName)
   | order by DurationSec desc
   ```
2. Check which phase is slowest:
   - **LoadProfile** — FSLogix profile load (check storage latency, profile size)
   - **ApplyGroupPolicy** — GPO processing (check number of GPOs, WMI filters)
   - **ShellReady** — Explorer shell startup (check startup scripts, AV scans)
   - **OnConnected** — Initial connection negotiation

### Resolution

| Phase | Resolution |
|---|---|
| LoadProfile > 15s | Optimize FSLogix storage (Premium tier, reduce profile size, check VHD fragmentation) |
| ApplyGroupPolicy > 15s | Audit applied GPOs (`gpresult /r`); remove unnecessary GPOs; optimize WMI filters |
| ShellReady > 15s | Check logon scripts, startup programs; disable unnecessary services; verify AV exclusions |
| OnConnected > 15s | Check network latency (RTTPerUser alert); verify gateway connectivity |

---

## AVD-Category-FrameQualityDegradation

**Signal:** Average frame delay > 300 ms or dropped frames > 15% per connection (ConnectionGraphicsData). *(Preview table)*

**Impact:** Users see visual stuttering, frozen screens, and degraded graphics quality. Particularly impactful for graphics-intensive workloads.

> **Note:** The `ConnectionGraphicsData` table is in **Preview**. Schema may change before GA.

### Triage Steps

1. **Identify degraded sessions:**
   ```kql
   ConnectionGraphicsData
   | where TimeGenerated > ago(1h)
   | summarize AvgDelay = avg(EstEndToEndDelayInMs), DropPct = avg(FramesSkippedPercentage) by CorrelationId
   | where AvgDelay > 300 or DropPct > 15
   | join kind=inner (WVDConnections | where TimeGenerated > ago(1h) | project CorrelationId, UserName, SessionHostName) on CorrelationId
   | project UserName, SessionHostName, AvgFrameDelay_ms = round(AvgDelay, 0), DroppedFramesPct = round(DropPct, 1)
   | order by AvgFrameDelay_ms desc
   ```
2. Check if affected hosts have GPUs (NV/NC-series) — frame quality issues without GPU may be expected under heavy load
3. Check GPU encoding time (if using AVD-Insights-Alerts GPUPerformance category)
4. Check bandwidth and RTT — frame quality degrades with network constraints

### Resolution

| Pattern | Resolution |
|---|---|
| GPU hosts with high delay | Update GPU drivers (NVIDIA GRID); reduce session density on GPU hosts |
| Non-GPU hosts | Expected under graphics load — reduce visual quality via RDP policy |
| Correlated with low bandwidth | Address network issues first (see BandwidthDrop runbook) |
| Correlated with high CPU | Address CPU saturation first — GPU encoding competes with CPU |

---

## General Escalation Path

1. **L1 (Automated):** Alert fires → webhook → Logic App → detailed email to ops team with WVDErrors query results
2. **L2 (Operations):** Follow runbook steps above; drain/restart hosts if needed; remediate user-level issues
3. **L3 (Engineering):** Persistent alerts across multiple host pools → investigate infrastructure (AD/DNS/network), open Azure support case

## Useful KQL Queries

### All errors in the last hour by category

```kql
WVDErrors
| where TimeGenerated > ago(1h)
| summarize Count=count() by CodeSymbolic
| order by Count desc
```

### Error trend over the last 24 hours

```kql
WVDErrors
| where TimeGenerated > ago(24h)
| summarize Count=count() by bin(TimeGenerated, 1h), CodeSymbolic
| render timechart
```

### Top affected users

```kql
WVDErrors
| where TimeGenerated > ago(4h)
| summarize ErrorCount=count(), DistinctErrors=dcount(CodeSymbolic) by UserName
| order by ErrorCount desc
| take 20
```

### Errors by session host

```kql
WVDErrors
| where TimeGenerated > ago(4h)
| extend SessionHost = tostring(split(_ResourceId, "/")[-1])
| summarize ErrorCount=count() by SessionHost, CodeSymbolic
| order by ErrorCount desc
```
