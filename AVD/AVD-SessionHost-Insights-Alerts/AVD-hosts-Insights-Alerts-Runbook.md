# AVD Insights Alerts - Operational Runbook

Procedures for responding to AVD Insights category-consolidated alerts. Each alert covers
multiple sub-signals - check the `Signal` column in the alert output to identify which
specific signal triggered.

---

## AVD-Insights-Category-SessionQuality

Fires when **any** session-quality signal breaches: InputDelay-Process, InputDelay-Session, RoundTripLatency, or UDPBandwidth.

### InputDelay (Process/Session)

**Signal:** User Input Delay > 200 ms average.

**Impact:** Users experience lag between typing/clicking and the application responding (per-process) or across the entire session (per-session).

**Triage Steps:**

1. Check CPU and memory on the affected host (`Perf | where Computer == "..." and ObjectName in ("Processor Information","Memory")`)
2. Identify which process has the highest input delay (per-process output)
3. Check if GPU rendering is constrained (RemoteFX Graphics counters)
4. Review concurrent session count vs host capacity

**Resolution:**

- Restart the offending process if consuming excessive resources
- Reduce session density on the host
- If persistent, scale out the host pool

### RoundTripLatency

**Signal:** RemoteFX Network TCP RTT > 150 ms average.

**Impact:** Users experience visual lag, delayed screen updates, poor streaming quality.

**Triage Steps:**

1. Check if the issue is isolated to specific hosts or widespread
2. Verify client location and network path (VPN, ExpressRoute, public internet)
3. Check Azure network health in the region
4. Review if packet loss accompanies the RTT increase

**Resolution:**

- If localized: investigate client-side network issues
- If widespread: check Azure region health, Gateway service health
- Consider enabling RDP Shortpath for managed networks

### UDPBandwidth

**Signal:** RemoteFX Network UDP bandwidth < 500 KB/s.

**Impact:** RDP Shortpath media quality degrades. Users may see frozen video, audio drops, or fall back to TCP-only transport.

**Triage Steps:**

1. Verify RDP Shortpath is enabled on the host pool and session hosts
2. Check if UDP connectivity is available (firewall rules, NSG, STUN/TURN)
3. Check client-side network - VPN, proxy, or strict firewall may block UDP

**Resolution:**

- Ensure UDP ports are open between clients and session hosts
- If VPN is involved, configure split-tunneling for RDP Shortpath traffic
- If UDP is unavailable, adjust `minUdpBandwidthKBps` threshold to suppress noise

---

## AVD-Insights-Category-HostPerformance

Fires when **any** host-performance signal breaches: CPUSaturation, MemoryPressure, MemoryCommitRatio, MemoryPagesPerSec, PageFaults-Baseline, or DiskTiming.

### CPUSaturation

**Signal:** Processor utilization > 90% sustained over 15 minutes.

**Impact:** All sessions on the host are degraded. Input delay increases, applications become unresponsive.

**Triage Steps:**

1. Identify top CPU-consuming processes
2. Check current session count vs capacity
3. Check for runaway processes (antivirus scans, Windows Update, print spooler)

**Resolution:**

- Drain sessions and restart if a runaway process is identified
- If session density is the cause, reduce max sessions or scale out
- Schedule maintenance tasks to off-peak hours

### MemoryPressure

**Signal:** Available memory < 512 MB.

**Impact:** Risk of OutOfMemory errors, session disconnections, profile corruption. **High severity.**

**Triage Steps:**

1. Check which processes are consuming the most memory
2. Check for memory leaks (process working set growing over time)
3. Verify committed memory vs physical RAM

**Resolution:**

- Immediately drain new sessions from the host
- Restart the host if memory cannot be reclaimed
- Increase VM size or reduce max sessions per host

### MemoryCommitRatio

**Signal:** Memory Committed Bytes In Use > 80%.

**Impact:** System is overcommitting virtual memory. Potential swap storms if demand spikes.

**Triage Steps:**

1. Check Available MBytes - if also low, memory is critically constrained
2. Identify top memory consumers by working set
3. Compare commit ratio trend over 24h - gradual rise suggests a memory leak

**Resolution:**

- If combined with low Available MBytes: drain sessions and restart host
- If a memory leak: identify and restart the leaking process
- Increase VM size if consistent overcommit
- Adjust `maxCommitPercent` up to 90% if workload legitimately uses high commit

### MemoryPagesPerSec

**Signal:** Memory Pages/sec > 100 sustained.

**Impact:** System is actively thrashing - hard page faults requiring disk I/O.

**Triage Steps:**

1. Check Available MBytes and Commit Ratio - are other memory signals also in the alert?
2. Check disk latency - heavy paging amplifies disk I/O load
3. Verify page file is on fast storage

**Resolution:**

- Address underlying memory pressure first
- Move page file to faster storage if disk latency is compounding
- If workload is legitimate, increase VM memory

### PageFaults-Baseline

**Signal:** Page Faults/sec exceeds 3x the 24-hour baseline.

**Impact:** Paging to disk more than usual, indicating memory pressure or workload spike.

**Resolution:**

- Address underlying memory pressure (see MemoryPressure above)
- If workload has legitimately changed, adjust `baselineMultiplier` threshold
- Ensure page file is on fast storage

### DiskTiming

**Signal:** Disk read/write latency > 25 ms average.

**Impact:** Slow profile loads, application hangs, poor user experience.

**Triage Steps:**

1. Check which disk (C:, profile disk, temp disk) is affected
2. Check disk queue length (if also high, it is I/O saturation)
3. Verify disk type (Standard HDD, Premium SSD, etc.)

**Resolution:**

- Upgrade disk tier if on Standard HDD/SSD
- Move FSLogix profiles to faster storage (Azure Files Premium, ANF)
- Exclude FSLogix VHD files from antivirus real-time scanning

---

## AVD-Insights-Category-DiskHealth

Fires when **any** disk-health signal breaches: DiskQueueLength or DiskFreeSpace.

### DiskQueueLength

**Signal:** Average disk queue length > 5.

**Triage:** Same as DiskTiming above. Queue length and latency are correlated.

### DiskFreeSpace

**Signal:** OS disk (C:) free space < 10%.

**Impact:** Session failures, inability to create temp files, system instability, potential BSOD.

**Triage Steps:**

1. Check what is consuming disk space (Windows logs, temp files, crash dumps)
2. Check if FSLogix local cache is on C: drive
3. Verify Windows Update cleanup has run

**Resolution:**

- Clean up Windows temp files, old update files
- Move FSLogix cache to a different disk
- Increase OS disk size
- Set up Disk Cleanup scheduled task

---

## AVD-Insights-Category-SessionLifecycle

Fires when **any** session-lifecycle signal breaches: SignInDegradation, CapacityPressure, or SessionImbalance.

### SignInDegradation

**Signal:** Average sign-in duration > 30 seconds from WVDCheckpoints.

**Impact:** Users wait excessively when logging in. May lead to timeout failures.

**Triage Steps:**

1. Check which sign-in phase is slowest (break down WVDCheckpoints by checkpoint name)
2. Check FSLogix profile load timing specifically
3. Verify Group Policy processing time

**Resolution:**

- If profile load is slow: optimize FSLogix storage, reduce profile size
- If GPO processing is slow: review applied policies, remove unnecessary GPOs
- If authentication is slow: check Entra ID / AD DS health

### CapacityPressure

**Signal:** Active sessions >= 90% of configured max session limit.

**Impact:** Host is approaching capacity. New connections may be refused at 100%.

**Triage Steps:**

1. Verify `maxSessionLimit` matches your actual host pool configuration
2. Check if other hosts in the pool have available capacity
3. Check if autoscale is configured and responding

**Resolution:**

- Scale out the host pool (add more session hosts)
- Enable or tune autoscale rules
- Adjust `maxSessionLimit` in config if your actual limit differs

### SessionImbalance

**Signal:** Disconnected/inactive sessions > 50% of total sessions on a host.

**Impact:** Inactive sessions consume RAM, CPU, and license capacity without serving users. Prevents autoscale from draining the host.

**Triage Steps:**

1. Check which users are disconnected and for how long
2. Verify session time limit GPO settings (disconnect timeout, idle timeout)
3. Check if autoscale is configured - imbalanced hosts block drain mode

**Resolution:**

- Log off stale disconnected sessions
- Configure GPO: `Set time limit for disconnected sessions` (e.g., 4-8 hours)
- Enable `Allow reconnection from original client only = No`

---

## AVD-Insights-Category-CorrelatedSignals

Fires when **any** correlated signal breaches: CorrelatedHosts or FSLogixCorrelation.

### CorrelatedHosts

**Signal:** Session host breaching 2+ performance signals simultaneously.
Alert output signal format: `CorrelatedHosts(<active-signals>)`, for example `CorrelatedHosts(CPU+Memory)`.

**Impact:** Host under significant stress across multiple dimensions. Higher likelihood of user-facing issues.

**Triage Steps:**

1. Check which signals are active (the alert output lists them)
2. Prioritize memory issues (most immediate impact)
3. Check session count vs capacity

**Resolution:**

- Drain sessions immediately and investigate
- This typically indicates the host needs to be restarted or resized

### FSLogixCorrelation

**Signal:** FSLogix operations > 30s AND host CPU > 85% or disk latency > 25ms.

**Impact:** Profile operations are slow because the host itself is constrained.

**Triage Steps:**

1. Distinguish between host-side and storage-side issues
2. If CPU is high, profile loads are competing with user workloads
3. If disk is slow, check if profile VHDs are on the same disk as the OS

**Resolution:**

- If host-constrained: reduce session density, scale out
- If disk-constrained: separate profile storage from OS disk
- If both: the host needs resizing

---

## AVD-Insights-Category-EventLogAlerts

Fires when FSLogix profile errors are detected in Windows Event Log.

### FSLogixProfileError

**Signal:** FSLogix profile attach/detach error events in Event Log.

**Impact:** Users cannot sign in or lose profile data. VHD mount failures cause temporary profiles.

**Triage Steps:**

1. Check Event Viewer: `Microsoft-FSLogix-Apps/Operational` and `Microsoft-FSLogix-Apps/Admin`
2. Common error codes:

   - 0x00000005: Access denied to VHD/X path
   - 0x00000020: File in use (orphaned lock)
   - 0x80070003: Path not found

3. Verify SMB connectivity to profile storage
4. Check if the user's VHD/X file exists and is not locked

**Resolution:**

- Access denied: verify NTFS and share permissions on the storage account
- File in use: check for orphaned sessions on other hosts locking the VHD
- Path not found: verify FSLogix registry settings (`VHDLocations`)
- For Azure Files: check private endpoint connectivity and firewall rules

---

## AVD-Insights-Category-GPUPerformance

Fires when GPU encoding time exceeds the RDP frame budget on GPU-enabled hosts.

### GPUEncodingTime

**Signal:** RemoteFX Graphics Average Encoding Time > 33 ms.

**Impact:** GPU cannot encode RDP frames within the 33ms budget (~30 FPS). Users see dropped frames, stuttering video, and degraded visual quality. Only fires on GPU-enabled hosts (NV/NC/ND-series).

**Triage Steps:**

1. Check GPU utilization via `nvidia-smi` or Azure Monitor GPU metrics
2. Identify which sessions/processes consume GPU - video, 3D apps, browser hardware acceleration
3. Check if the GPU driver is current (NVIDIA GRID drivers for NV-series)
4. Review Frames Skipped / Insufficient Resources counter

**Resolution:**

- Reduce session density on GPU hosts
- Update GPU drivers to the latest GRID version
- Disable hardware acceleration in applications that do not need it
- If persistent: upgrade to a larger GPU SKU
- Adjust `maxEncodingTimeMs` to 50 if 30 FPS is not required

---

## General Escalation Path

1. **L1 (Automated):** Alert fires -> webhook -> Logic App -> email to ops team
2. **L2 (Operations):** Follow runbook steps above, drain host if needed
3. **L3 (Engineering):** Persistent alerts across multiple hosts -> architecture review, capacity planning
