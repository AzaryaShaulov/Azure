# Compatibility score (0-100)

Weights live in `data/scoring-weights.json`. The score ranks valid candidates. It **never**
overrides a failed mandatory gate: a rejected candidate is shown with its score and rejection reason, but it is never
recommended.

| Criterion | Weight | Full points | Partial / zero |
|---|---:|---|---|
| CPU vendor match | 20 | Same vendor (Intel/AMD/ARM) | 0 if different |
| CPU architecture match | 10 | Same (x64/Arm64) | 0 (also a mandatory fail) |
| Workload family match | 10 | Same family letter (D->D) | 8 for a Microsoft migration-guide cross-family target (e.g. Av2->B/D, G->L); 0 otherwise |
| vCPU match | 10 | Equal | 9 if up to +25%; 6 if up to 2x; 3 if above 2x; 0 if smaller (excluded anyway); 5 if current unknown |
| Memory match | 10 | 0.97x-1.25x | 6 if up to 2x; 3 if above; 0 if smaller; 5 if unknown |
| Memory per vCPU | 5 | Ratio within ~10% | 3 if within ~50%; 1 otherwise; 2.5 if unknown |
| Storage capability | 10 | Premium parity (4) + temp-disk parity (3) + ephemeral/Ultra support where used (3) | Each part 0 when lost |
| Disk throughput / IOPS | 5 | Uncached IOPS and MBps >= current | 3 if >= 90%; 1 below; 2.5 if unknown |
| Network capability | 5 | Accelerated networking parity (3) + max NICs >= current (2) | 1 if max NICs covers only what is used |
| NIC / disk limits | 5 | Max NICs >= NICs used (2.5) + max data disks >= disks used (2.5) | 0 per part when exceeded |
| AZ / regional support | 5 | Available in region (3) + offered and unrestricted in VM zone (2) | 0 per part |
| Other features | 5 | Hyper-V generation (2), security type (1), encryption at host (1), disk controller (1) | 0 per part |

Bands:

| Score | Band |
|---|---|
| 90-100 | Excellent Match |
| 80-89 | Good Match |
| 70-79 | Acceptable with Review |
| below 70 | Manual Review Required |

## Capability regressions are never hidden

The primary recommendation may lower a VM-level cap that is not a mandatory gate, such as uncached disk IOPS/MBps.
For example, Standard_DS3_v2 (12,800 IOPS) -> Standard_D4ds_v5 (6,400 IOPS). When that happens:

- the reduction appears in **Material Differences** as `Reduced`;
- a validation item is added: *"Capability reduced ... validate against observed disk throughput or use the
  capability-preserving alternative"*. Confidence therefore cannot be HIGH;
- the smallest same-series size that preserves the caps is evaluated as a *Capability-preserving* variant and is
  offered as an alternative. This lets the owner choose between licensing/cost (matching vCPU) and throughput parity.

## Candidate CSV columns

`candidates.csv` includes each criterion's points (`S_CpuVendor`, `S_Architecture`, `S_Family`, `S_vCpu`, `S_Memory`,
`S_MemPerVcpu`, `S_Storage`, `S_DiskThroughput`, `S_Network`, `S_NicDiskLimits`, `S_ZoneRegion`, `S_Other`), so every
score can be audited.
