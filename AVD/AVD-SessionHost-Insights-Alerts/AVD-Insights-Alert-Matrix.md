# AVD Insights Alert Matrix

Complete reference for all 7 category-consolidated Insights alerts. Each category alert unions multiple sub-signals
into a single scheduled-query rule — the alert fires when ANY signal in the category breaches its threshold.

> **Naming convention:** `AVD-Insights-Category-{CategoryName}` (e.g., `AVD-Insights-Category-SessionQuality`)

> **Per-signal severity:** The severity shown per signal in the tables below is informational — it indicates the relative criticality of each signal. The actual alert rule fires at a **single severity** defined in `alerts-config.insights.json` (typically Severity 1 for Error or Severity 2 for Warning).

## Session Quality — `AVD-Insights-Category-SessionQuality`

| Signal | Severity | Counter | Threshold | Window | Frequency |
|--------|----------|---------|-----------|--------|-----------|
| InputDelay-Process | 2 (Warn) | User Input Delay per Process / Max Input Delay | Avg > 200 ms (min 3 samples) | PT15M | PT10M |
| RoundTripLatency | 2 (Warn) | RemoteFX Network / Current TCP RTT | Avg > 150 ms (min 3 samples) | PT15M | PT10M |
| InputDelay-Session | 2 (Warn) | User Input Delay per Session / Max Input Delay | Avg > 200 ms (min 3 samples) | PT15M | PT10M |
| UDPBandwidth | 2 (Warn) | RemoteFX Network / Current UDP Bandwidth | Avg < 500 KB/s (min 3 samples) | PT15M | PT10M |

**Input Delay (per Process)** measures time between user input (keyboard/mouse) and the application processing it. High values indicate the session host is overloaded or there is a graphics rendering bottleneck.

**Round-Trip Latency** measures TCP RTT between the client and session host. High values indicate network path issues, WAN congestion, or proximity problems.

**Input Delay (per Session)** measures aggregate session-level input delay. Complements per-process delay by showing overall session responsiveness degradation.

**UDP Bandwidth** monitors RemoteFX Network UDP throughput. Low bandwidth indicates RDP Shortpath connectivity issues or network congestion affecting media quality.

## Host Performance — `AVD-Insights-Category-HostPerformance`

| Signal | Severity | Counter | Threshold | Window | Frequency |
|--------|----------|---------|-----------|--------|-----------|
| CPUSaturation | 2 (Warn) | Processor Information(_Total) / % Processor Time | Avg > 90% (min 3 samples) | PT15M | PT10M |
| MemoryPressure | 1 (Error) | Memory / Available MBytes | Avg < 512 MB (min 3 samples) | PT15M | PT10M |
| MemoryCommitRatio | 2 (Warn) | Memory / % Committed Bytes In Use | Avg > 80% (min 3 samples) | PT15M | PT10M |
| MemoryPagesPerSec | 2 (Warn) | Memory / Pages/sec | Avg > 100 (min 3 samples) | PT15M | PT10M |
| PageFaults-Baseline | 2 (Warn) | Memory / Page Faults/sec | Avg > 3x 24h baseline (min 10 baseline samples) | PT30M | PT10M |
| DiskTiming | 2 (Warn) | LogicalDisk(*) / Avg. Disk sec/Read + sec/Write | Avg > 25 ms (min 3 samples) | PT15M | PT10M |

**CPU Saturation** fires when average CPU exceeds 90% over 15 minutes. Multiple samples required to avoid transient spikes.

**Memory Pressure** fires when available memory drops below 512 MB. This is a high-severity alert as low memory directly impacts user sessions and can cause OutOfMemory errors.

**Memory Commit Ratio** tracks committed bytes in use as a percentage. Values above 80% indicate memory overcommit risk where the system may need to page heavily, even if Available MBytes hasn't dropped yet.

**Memory Pages/sec** measures hard page faults requiring disk I/O. Sustained values above 100/sec indicate memory thrashing — the system is actively swapping between RAM and disk. More immediate than Page Faults which uses a dynamic baseline.

**Page Faults** uses a dynamic 24-hour baseline with a 3x multiplier. This adapts to the host's normal workload pattern rather than using a static threshold.

**Disk Timing** monitors both read and write latency. 25ms (0.025s) is the default threshold; values above this typically indicate storage I/O bottleneck.

## Disk Health — `AVD-Insights-Category-DiskHealth`

| Signal | Severity | Counter | Threshold | Window | Frequency |
|--------|----------|---------|-----------|--------|-----------|
| DiskQueueLength | 2 (Warn) | PhysicalDisk(*) / Avg. Disk Queue Length | Avg > 5 (min 3 samples) | PT15M | PT10M |
| DiskFreeSpace | 1 (Error) | LogicalDisk(C:) / % Free Space | Avg < 10% | PT15M | PT10M |

**Disk Queue Length** indicates how many I/O operations are waiting. Sustained values above 5 suggest the disk subsystem cannot keep up.

**Disk Free Space** monitors the OS drive (C:). Below 10% free space can cause session failures, profile issues, and system instability.

## Session Lifecycle — `AVD-Insights-Category-SessionLifecycle`

| Signal | Severity | Source Table | Threshold | Window | Frequency |
|--------|----------|-------------|-----------|--------|-----------|
| SignInDegradation | 2 (Warn) | WVDCheckpoints | Avg sign-in > 30s (min 3 samples) | PT15M | PT10M |
| CapacityPressure | 1 (Error) | WVDAgentHealthStatus | Sessions >= 90% of max (configurable `_maxSessionLimit`, default: 50) | PT15M | PT10M |
| SessionImbalance | 2 (Warn) | Perf (Terminal Services) | Inactive sessions > 50% of total (min 2 sessions) | PT15M | PT10M |

**Sign-In Degradation** calculates total sign-in duration from WVDCheckpoints correlation events. Over 30 seconds indicates profile load, authentication, or resource contention issues.

**Capacity Pressure** fires when a session host reaches 90% of the configured `_maxSessionLimit` (default: 50). The alert uses a configurable static limit rather than Azure Resource Graph, since ARG cross-resource queries are not supported in scheduled query alert context. Set `_maxSessionLimit` in the config to match your actual host pool `maxSessionLimit`.

**Session Imbalance** detects hosts where more than half the sessions are disconnected/inactive but still consuming resources. This drains host capacity without serving active users and blocks autoscale from draining the host.

## Correlated Signals — `AVD-Insights-Category-CorrelatedSignals`

| Signal | Severity | Source | Threshold | Window | Frequency |
|--------|----------|--------|-----------|--------|-----------|
| CorrelatedHosts | 1 (Error) | Perf (CPU+Memory+Disk) | 2+ signals breaching simultaneously | PT15M | PT10M |
| FSLogixCorrelation | 2 (Warn) | WVDCheckpoints + Perf | Profile load > 30s AND (CPU > 85% OR Disk > 25ms) | PT30M | PT10M |

**Correlated Hosts** identifies session hosts failing multiple performance signals at once. A host with high CPU *and* low memory is more critical than either signal alone.

**FSLogix Correlation** connects slow profile operations with host resource constraints. Helps distinguish between storage-side FSLogix issues and host-side performance bottlenecks.

## Event Log Alerts — `AVD-Insights-Category-EventLogAlerts`

| Signal | Severity | Source Table | Threshold | Window | Frequency |
|--------|----------|-------------|-----------|--------|-----------|
| FSLogixProfileError | 1 (Error) | Event (FSLogix logs) | >= 1 error event | PT15M | PT10M |

**FSLogix Profile Error** monitors Windows Event Log for FSLogix profile attach/detach failures and VHD errors. These events (from the `Microsoft-FSLogix-Apps/Operational` and `Microsoft-FSLogix-Apps/Admin` providers) indicate profile container problems that directly impact user sign-in.

## GPU Performance — `AVD-Insights-Category-GPUPerformance`

| Signal | Severity | Counter | Threshold | Window | Frequency |
|--------|----------|---------|-----------|--------|-----------|
| GPUEncodingTime | 2 (Warn) | RemoteFX Graphics / Average Encoding Time | Avg > 33 ms (min 3 samples) | PT15M | PT10M |

**GPU Encoding Time** monitors the RemoteFX Graphics encoding pipeline. The 33ms threshold corresponds to the RDP frame budget (~30 FPS). Values above this mean the GPU cannot encode frames fast enough, resulting in dropped frames and visual degradation. Only applicable to GPU-enabled session hosts (NV/NC/ND-series VMs). Deploy with `-CategoryFilter GPUPerformance`.

## Threshold Tuning Guide

All thresholds live in `alerts-config.insights.json`. Common adjustments:

| Scenario | Parameter | Recommended Change |
|----------|-----------|-------------------|
| VDI with heavy GPU workloads | `maxCpuPercent` | Increase to 95% |
| Hosts with 4 GB RAM | `minAvailableMemoryMB` | Decrease to 256 |
| Premium SSD storage | `maxDiskLatencySeconds` | Decrease to 0.01 (10ms) |
| Large host pool (50+ sessions) | `maxSessionLimit` | Set to actual host pool max |
| Spiky workloads | `minSampleCount` | Increase to 5-6 |
| Profile storage on Azure Files | `maxProfileLoadMs` | Increase to 45000 |
| Memory-intensive apps | `maxCommitPercent` | Increase to 90% |
| High-throughput RDP Shortpath | `minUdpBandwidthKBps` | Increase to 1000 |
| Non-GPU hosts | GPUPerformance category | Skip with `-CategoryFilter` (exclude) |
| Hosts with many disconnected users | `maxInactivePercent` | Increase to 70% |
