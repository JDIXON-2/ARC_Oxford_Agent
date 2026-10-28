# GPU specs for resource estimation

Memory and node layout: [ARC systems page](https://arc-user-guide.readthedocs.io/en/latest/arc-systems.html) and live `sinfo` (the `gpu_mem` feature, which is what the scheduler matches). Throughput: vendor datasheets, **dense** tensor-core TFLOPS (no sparsity). Where ARC does not state the form factor, the slower variant is listed (conservative).

| Host | sinfo `gpu_sku` | `gpu_mem` | cc | BF16 | Dense BF16/FP16 TFLOPS | Mem BW (TB/s) | Partitions |
|---|---|---|---|---|---|---|---|
| **morph (local)** | H100 NVL | 94 GB | 9.0 | yes | 835 | 3.9 | — |
| ARC | `V100` | 32 GB | 7.0 | **no** | 112 (FP16, PCIe) | 0.90 | short |
| ARC | `RTX` (Titan RTX) | 24 GB | 7.5 | **no** | 130 (FP16) | 0.67 | short |
| ARC | `RTX8000` | 48 GB | 7.5 | **no** | 130 (FP16) | 0.67 | short, medium, long, devel, interactive |
| ARC | `RTX-A6000` | 48 GB | 8.6 | yes | 155 | 0.77 | short |
| ARC | `L40S` | 48 GB | 8.9 | yes | 362 | 0.86 | short, medium, long |
| ARC | `A100` | 40 GB | 8.0 | yes | 312 | 1.56 | short, medium, long |
| ARC | `H100` (4×, Icelake nodes) | 80 GB | 9.0 | yes | 756 (PCIe) | 2.0 | short |
| ARC | `H100` (8×, NVLink nodes) | 80 GB | 9.0 | yes | 989 (SXM) | 3.35 | short, medium, long |
| ARC | `H100` (94 GB nodes) | 94 GB | — | yes | 835 (NVL) | 3.9 | short |

Because `gpu_sku:H100` can land on any H100 variant, estimate H100 time with the slowest one (756 TFLOPS, 2.0 TB/s).

## Notes
- **cc < 8.0 (V100, Titan RTX, RTX8000) has no native BF16.** If the run uses `torch.bfloat16` anywhere (model dtype, autocast), exclude these.
- Usable memory is about 1–2 GB below the nominal `gpu_mem` (CUDA context and allocator overhead).
- Morph's H100 NVL is faster than every ARC GPU except H100-SXM, so ARC times are almost always longer than local times.
