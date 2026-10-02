# AVD Session Host Performance Counters

## Counters Collected (Default - 28 Total)

### CPU (1)

| Counter | Description |
| ------- | ----------- |
| `Processor Information(_Total)\% Processor Time` | CPU utilization |

### Memory (4)

| Counter | Description |
| ------- | ----------- |
| `Memory\Available MBytes` | Free memory |
| `Memory\% Committed Bytes In Use` | Memory pressure |
| `Memory\Pages/sec` | Hard page faults requiring disk I/O |
| `Memory\Page Faults/sec` | Total page faults (soft + hard) |

### Disk Capacity (1)

| Counter | Description |
| ------- | ----------- |
| `LogicalDisk(*)\% Free Space` | Disk free space percentage (per volume) |

### Disk Latency (6)

| Counter | Description |
| ------- | ----------- |
| `LogicalDisk(*)\Avg. Disk sec/Read` | Logical disk read latency |
| `LogicalDisk(*)\Avg. Disk sec/Write` | Logical disk write latency |
| `LogicalDisk(*)\Avg. Disk sec/Transfer` | Logical disk overall latency |
| `PhysicalDisk(*)\Avg. Disk sec/Read` | Physical disk read latency |
| `PhysicalDisk(*)\Avg. Disk sec/Write` | Physical disk write latency |
| `PhysicalDisk(*)\Avg. Disk sec/Transfer` | Physical disk overall latency |

### Disk Queue (2)

| Counter | Description |
| ------- | ----------- |
| `LogicalDisk(*)\Current Disk Queue Length` | Logical disk queue depth |
| `PhysicalDisk(*)\Avg. Disk Queue Length` | Physical disk average queue depth |

### AVD Session Quality (5)

| Counter | Description |
| ------- | ----------- |
| `User Input Delay per Process(*)\Max Input Delay` | Per-process input delay |
| `User Input Delay per Session(*)\Max Input Delay` | Per-session input delay |
| `RemoteFX Network(*)\Current TCP RTT` | TCP round-trip latency |
| `RemoteFX Network(*)\Current UDP Bandwidth` | UDP bandwidth (RDP Shortpath) |
| `RemoteFX Graphics(*)\Average Encoding Time` | GPU encoding time (GPU hosts) |

### AVD Session Lifecycle (3)

| Counter | Description |
| ------- | ----------- |
| `Terminal Services\Active Sessions` | Active session count per host |
| `Terminal Services\Inactive Sessions` | Disconnected/idle session count |
| `Terminal Services\Total Sessions` | Total session count per host |

### Network Bandwidth (4)

| Counter | Description |
| ------- | ----------- |
| `Network Adapter(*)\Bytes Total/sec` | Total network throughput |
| `Network Adapter(*)\Bytes Received/sec` | Inbound network bandwidth |
| `Network Adapter(*)\Bytes Sent/sec` | Outbound network bandwidth |
| `Network Adapter(*)\Current Bandwidth` | Network adapter link speed |

### Network Queue (1)

| Counter | Description |
| ------- | ----------- |
| `Network Adapter(*)\Output Queue Length` | Network output queue depth |
