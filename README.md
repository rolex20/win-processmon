# win-processmon (PowerShell performance toolkit)

This repository started with **`ProcessMon.ps1`**: a focused monitor to catch what Windows launches in the background while gaming, especially short-lived or periodic tasks that can line up with frame-time spikes (for example `TiWorker.exe`, `CompatTelRunner.exe`, and similar maintenance/telemetry processes).

From there, the workflow expanded into additional scripts to test mitigation strategies on hybrid CPUs (Alder Lake class):
- first by steering some background activity toward efficiency cores,
- then by validating behavior with `Stutter-Hunter.ps1`,
- and finally by refining detection logic in related tooling so many targets are handled with **Idle priority** adjustments instead of broader, more aggressive changes.

The goal is practical control and observability: identify interference, test changes, measure results, and keep what actually helps.

---

## Tech snapshot

- **PowerShell 5.1 / Windows PowerShell** automation for low-level system workflows.
- **.NET Runspaces** for true multi-threaded producer/consumer design.
- **WMI/CIM event tracing** (`Win32_ProcessStartTrace`, `Win32_ProcessStopTrace`) for low-latency process lifecycle capture.
- **Bulk CIM performance sampling** (`Win32_PerfFormattedData_PerfProc_Process`) to reduce per-process query overhead.
- **Thread-safe shared state** with synchronized hashtables and explicit `Monitor` locking.
- **Dynamic C# compilation via `Add-Type`** for high-frequency loops with lower PowerShell overhead.
- **`System.Diagnostics.Process` API** usage for CPU time deltas, kernel/user split, working set behavior, priority classes, and affinity control.
- **Windows scheduling controls**: process **PriorityClass** (including Idle/BelowNormal) and **ProcessorAffinity** masks.
- **NVML interop (P/Invoke to `nvml.dll`)** for direct NVIDIA telemetry (clock, temp, utilization, VRAM).
- **`nvidia-smi` CLI integration** for quick GPU clock/temperature polling.
- **CSV reporting pipeline** for offline filtering/sorting and post-session analysis.
- **Operational UX features**: optional text-to-speech alerts, console health checks, and self-elevation patterns for admin-required visibility.

---

## Scripts

### `ProcessMon.ps1`

### Purpose
Real-time process start/stop monitor for Windows 10/11 focused on finding background activity that correlates with in-game stutter or input hitching.

### What it does
- Subscribes to WMI process lifecycle events (`start` and `stop`) with low latency.
- Captures process metadata close to launch time: owner/SID, command line, parent process, session, executable path.
- Samples CPU, memory, and I/O metrics in a **background runspace** and tracks peaks/totals.
- Exports a per-process lifetime report to CSV.
- Optional TTS announces process activity while you stay in-game.

### Key parameters
- `-SampleIntervalMs` (default `1000`) for metric sampling frequency.
- `-OutputCsv` to choose report path.
- `-Quiet` to reduce console output.
- `-NoTts` to disable voice alerts.
- `-ExcludeNames` to suppress known noisy processes.

### Best use
Run before reproducing a stutter scenario, then sort CSV by CPU/I/O peaks and short-lived events around the time you felt the hitch.

---

### `Stutter-Hunter.ps1`

### Purpose
High-frequency interference detector designed for hybrid-CPU gaming scenarios where short spikes (not average load) are the real problem.

### What it does
- Uses a tight loop (default `100ms`) to compare per-process CPU time deltas.
- Flags processes that exceed configurable CPU spike thresholds.
- Classifies risk patterns such as:
  - high-priority background spikes,
  - kernel-heavy spikes (driver/AV style behavior),
  - abrupt memory working-set churn used as a lightweight paging pressure proxy.
- Emits timestamped alerts and optional beep cues for critical events.

### Key parameters
- `-GameProcessName` to exclude the active game executable.
- `-SampleIntervalMs` for detection granularity.
- `-CpuSpikeThreshold` for alert sensitivity.
- `-HardFaultThreshold` (declared for tuning workflows; logic currently focuses on fast proxies).

### Best use
Run during gameplay to catch interference in real time, then apply policy changes (priority/affinity) only where repeated offenders are confirmed.

---

### `read-gpu-clocks.ps1`

### Purpose
Minimal overhead polling script for NVIDIA GPU clocks and temperature using `nvidia-smi`.

### What it does
- Sets its own process priority to **Idle**.
- Calls `nvidia-smi` in a loop every 5 seconds.
- Prints SM clock, memory clock, and GPU temperature.

### Best use
Quick sanity check while testing game settings, driver changes, or background mitigation scripts.

---

### `read-gpu-clocks-directly.ps1`

### Purpose
Direct NVML-based GPU telemetry script with controllable process scheduling (priority + affinity).

### What it does
- Loads `nvml.dll` and binds native NVML methods through C# interop (`Add-Type`).
- Reads:
  - graphics clock (GHz),
  - GPU temperature,
  - GPU utilization,
  - VRAM used percentage.
- Sets the script process to **Idle** and applies a configurable affinity mask.
- Streams timestamped telemetry once per second.

### Best use
When you want direct API-level GPU telemetry and deterministic script scheduling behavior during performance experiments.

---

## Practical workflow

1. **Observe process behavior** with `ProcessMon.ps1` and identify repeat offenders.
2. **Validate interference patterns** live with `Stutter-Hunter.ps1`.
3. **Apply conservative scheduling policy** (often priority-first, e.g., Idle) before stronger affinity constraints.
4. **Correlate with GPU state** using one of the GPU scripts to rule in/out GPU-side bottlenecks.
5. Iterate only on changes that consistently improve frame-time stability.

---

## Requirements

- Windows 10/11
- PowerShell 5.1
- Administrator privileges recommended for full system/process visibility
- NVIDIA tooling for GPU scripts:
  - `nvidia-smi.exe` on PATH (or default NVIDIA install location)
  - `nvml.dll` available for the direct NVML script

