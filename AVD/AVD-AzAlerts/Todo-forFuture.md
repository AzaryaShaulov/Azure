# AVD Alerts — Future: WVD Diagnostic Log Table Alerts

> **Status**: ✅ **IMPLEMENTED** — All 8 alerts below have been added to `AVD-Category-Alerts.ps1` (March 2026).
> See `AVD-Alerts-Matrix.md` and `AVD-Alerts-Runbook.md` for full documentation.

> **Scope**: Alerts that rely on AVD-native diagnostic log tables routed via host pool diagnostic settings.
> These are _separate_ from the session-host Perf/Event/InsightsMetrics alerts in `private-dev/AVD-SessionHost-Insights/`.
> **Prerequisite**: Host pool diagnostic settings must route `allLogs` (or the specific tables below) to the target Log Analytics workspace.

---

## Tier 2  High Value (WVDConnections, WVDAgentHealthStatus, WVDConnectionNetworkData)

### 1. Connection-FailureRate
- **Table**: `WVDConnections`
- **Signal**: Spike in connections where `State == "Failed"` per host pool within a sliding window.
- **Why**: Users unable to connect is the highest-impact operational signal. Not covered by any Perf counter.
- **Suggested threshold**: > 5 failed connections in 15 min per host pool.
- **KQL sketch**:
```kql
WVDConnections
| where TimeGenerated > ago(15m)
| where State == "Failed"
| summarize FailedCount = count() by _ResourceId
| where FailedCount > 5
```

### 2. Disconnection-Spike
- **Table**: `WVDConnections`
- **Signal**: Abnormal disconnection rate across session hosts, indicating infrastructure or network instability.
- **Why**: Mass disconnects point to gateway, networking, or host pool-level issues invisible to per-host Perf counters.
- **Suggested threshold**: > 10 disconnections in 15 min across a host pool.
- **KQL sketch**:
```kql
WVDConnections
| where TimeGenerated > ago(15m)
| where State == "Completed"
| where ConnectionType == "Disconnected"
| summarize DisconnectCount = count() by _ResourceId, SessionHostName
| where DisconnectCount > 10
```

### 3. Unhealthy-Hosts
- **Table**: `WVDAgentHealthStatus`
- **Signal**: Session hosts reporting `Status != "Available"` (Unavailable, NeedsAssistance, Shutdown, Upgrading).
- **Why**: Current capacity alert only checks _healthy_ hosts. This catches hosts falling out of service entirely.
- **Suggested threshold**: Any host with non-Available status for > 2 consecutive heartbeats.
- **KQL sketch**:
```kql
WVDAgentHealthStatus
| where TimeGenerated > ago(15m)
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where Status != "Available"
| project SessionHostName, Status, LastHeartBeat = TimeGenerated
```

### 4. Stale-Heartbeat
- **Table**: `WVDAgentHealthStatus`
- **Signal**: `LastHeartBeat` older than threshold, indicating agent communication failure or zombie hosts.
- **Why**: Hosts that stop heartbeating are effectively dead but may still appear in the host pool.
- **Suggested threshold**: LastHeartBeat > 5 minutes ago.
- **KQL sketch**:
```kql
WVDAgentHealthStatus
| summarize arg_max(TimeGenerated, *) by SessionHostName
| where TimeGenerated < ago(5m)
| project SessionHostName, Status, StaleSinceMin = datetime_diff('minute', now(), TimeGenerated)
```

### 5. Bandwidth-Drop
- **Table**: `WVDConnectionNetworkData`
- **Signal**: `EstAvailableBandwidthKBps` drops below threshold per connection.
- **Why**: Protocol-agnostic, per-connection, more accurate than the host-level RemoteFX counter.
- **Suggested threshold**: P10 bandwidth < 500 KBps.
- **KQL sketch**:
```kql
WVDConnectionNetworkData
| where TimeGenerated > ago(15m)
| summarize P10BW = percentile(EstAvailableBandwidthKBps, 10) by CorrelationId
| where P10BW < 500
```

---

## Tier 3  Medium Value (WVDConnectionNetworkData, WVDCheckpoints)

### 6. RTT-PerUser
- **Table**: `WVDConnectionNetworkData` joined with `WVDConnections`
- **Signal**: Per-user P95 RTT from connection-level data.
- **Why**: Supplements host-level RemoteFX counter with user-attributed latency  helps identify which users have bad networks.
- **Suggested threshold**: P95 RTT > 200 ms.

### 7. TimeToConnect-Breakdown
- **Table**: `WVDCheckpoints`
- **Signal**: Alert on prolonged logon phases  Profile load, GPO processing, Shell start.
- **Why**: More granular than overall sign-in duration. Helps pinpoint _which phase_ of sign-in is slow (FSLogix profile, GPO, shell).
- **Suggested threshold**: Any phase > 15 seconds.

---

## Tier 4  Conditional / Preview

### 8. FrameQuality-Degradation (Preview)
- **Table**: `ConnectionGraphicsData`
- **Signal**: End-to-end frame delay > 300 ms or > 15% dropped frames.
- **Why**: Catches graphics pipeline issues invisible to CPU/memory counters.
- **Status**: Table is in **preview**  schema may change before GA.
- **When to use**: Environments with graphics-intensive workloads (CAD, video editing, media).

---

## Implementation Notes

- All alerts above require **host pool diagnostic settings** sending logs to the **same Log Analytics workspace** used by the session-host monitoring DCR.
- The deployment script should be added to `AVD/AVD-AzAlerts/` (alongside `AVD-Category-Alerts.ps1`) since these are host-pool-scoped alerts, not session-host-scoped.
- Reuse the existing `New-OrSkip-ScheduledQueryAlert` pattern from `AVD-Category-Alerts.ps1`.
- These alerts can share the same Logic App / webhook action group already deployed by `AVD-Deploy-Alert-LogicApp.ps1`.

