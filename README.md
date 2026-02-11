# ProcessMon (PowerShell)

When a game stutters, the obvious suspects (GPU driver, shaders, “bad optimization”) get all the blame — but a lot of “mystery” hitching is really Windows doing something in the background at exactly the wrong time. **ProcessMon** is a lightweight, real-time Windows process monitor that watches for **process start/stop events** and captures a small set of **CPU / memory / I/O** signals so you can correlate “I felt that hitch” with “this thing launched.”

**Tech snapshot:** PowerShell 5.1 + .NET Runspaces (true multi-threading), WMI/CIM event tracing (`Win32_ProcessStartTrace` / `Win32_ProcessStopTrace`), bulk CIM performance sampling (`Win32_PerfFormattedData_PerfProc_Process`), thread-safe shared state with synchronized hashtables + `Monitor` locks, and CSV reporting.

---

## What it does (and doesn’t)

**It does:**
- Detect **process starts/stops** with very low latency (WMI event traces)
- Optionally track **all processes**, including those already running at startup (`-TrackAll`)
- Capture per-process peaks for:
  - CPU (%)
  - Working Set / Private Bytes
  - Disk I/O read/write rate (Mbps) + estimated totals
- Enrich events with useful context:
  - Owner (user/SID), command line, parent process name, session id
- Export a **CSV report** you can sort/filter after a gaming session

**It doesn’t:**
- Replace Windows Performance Recorder (WPR), ETW traces, or deep profilers  
  This is meant to answer: *“What fired up right when my frame-time spiked?”*
- Guarantee visibility into every system/service process unless you run as Admin
- By default, it does **not** report processes already running before capture begins (use `-TrackAll` for that)

---

## Why you might use it (gaming & sim racing & sim flying)

If you’ve ever had:
- microstutter / “FPS lag” that comes and goes
- a periodic hitch every few minutes
- a random freeze when a launcher, updater, overlay, anti-cheat, or background helper wakes up…

…start ProcessMon, reproduce the issue, then check the CSV for short-lived processes or surprise I/O spikes.

---

## Requirements

- Windows 10/11
- PowerShell 5.1 (works great in Windows PowerShell)
- **Administrator** is recommended for full visibility (the script will warn if you’re not)

No external dependencies.

---

## Quick start

Run from an elevated PowerShell prompt:

```powershell
# Basic run (1s sampling, CSV saved next to the script)
.\ProcessMon.ps1
````

Higher resolution sampling (more overhead):

```powershell
.\ProcessMon.ps1 -SampleIntervalMs 250
```

Save the report to a specific path:

```powershell
.\ProcessMon.ps1 -OutputCsv "C:\Temp\ProcessMon.csv"
```

Run quietly (no console spam, just the CSV at the end):

```powershell
.\ProcessMon.ps1 -Quiet
```

Exclude noisy process names (defaults already exclude common ones like `svchost.exe`, `msedge.exe`, etc.):

```powershell
.\ProcessMon.ps1 -ExcludeNames @("svchost.exe","msedge.exe","Discord.exe","Steam.exe")
```

Track all processes (report pre-existing ones only if they cross the CPU threshold):

```powershell
.\ProcessMon.ps1 -TrackAll
```

Customize the CPU threshold for pre-existing/resynced processes:

```powershell
.\ProcessMon.ps1 -TrackAll -MinCpuPeakPct 8
```

### Stopping the capture

Use **Ctrl+C** (or close the window). On shutdown, the script writes the report and prints the output path.

---

## What’s in the CSV

Each row represents a process lifetime (start → stop), with peaks and totals captured during that window.

Common columns you’ll care about:

* `Name`, `ProcId`
* `ParentName`, `ParentProcId`
* `StartTime`, `StopTime`, `DurationSec`
* `StartCaptured`, `StartSource`, `ObservedStartTime`, `StopReason`
* `Owner`, `OwnerSid`, `IsSystemAccount`, `IsServiceAccount`
* `CommandLine` (trimmed in console output; full in CSV)
* `CpuPeakPct`
* `WorkingSetPeakMB`, `PrivateBytesPeakMB` (decimal MB, not MiB)
* `ReadMbpsPeak`, `WriteMbpsPeak`
* `TotalReadMB`, `TotalWriteMB`
* `Visibility` / `AccessRestricted` (helps explain why some metadata is missing)
* `ProcessCreationTime` (when metadata is captured)

Tip: Sort by `CpuPeakPct`, `ReadMbpsPeak`, `WriteMbpsPeak`, or `DurationSec` to surface the usual troublemakers fast.

Per-process JSON is generated for every emitted row (one JSON file per process).

---

## How it works (high level)

ProcessMon is intentionally split into two lanes:

1. **Main thread (event listener + UI/logging)**

* Subscribes to WMI event traces for process start/stop
* Captures “who/what launched” metadata immediately (owner, command line, parent)
* Tracks active PIDs in shared state

2. **Background runspace (metrics sampler)**

* Samples performance counters via a **single bulk WMI/CIM query** and maps metrics back to tracked PIDs
* Updates peaks/totals in shared state without blocking event detection

There’s also a simple health check: if the background runspace dies, the main loop reports it and exits cleanly.

---

## Notes & gotchas

* **Sampling overhead:** Lower `-SampleIntervalMs` gives better timing resolution but increases WMI/CIM load.
* **Admin visibility:** Without elevation, some system/service metadata may show up as restricted.
* **Anti-cheat / protected processes:** Some environments are noisy or restrictive; the sampler is designed to fail softly rather than crash.

---

## Text-to-Speech

The script includes Text-to-Speech (useful if you want audible “something started/stopped” cues while you’re in-game). It’s enabled by default. To disable TTS alerts, run:

```powershell
.\ProcessMon.ps1 -NoTts
```

---

## keywords

Windows 11 process monitor, PowerShell process monitoring, real-time process start trace, FPS stutter fix, microstutter diagnosis, sim racing performance tuning, Forza Motorsport stutter, CPU spike detector, background process detection, disk I/O latency, WMI event trace, CIM performance counters.


Real-time Windows 10/11 process start/stop monitor for diagnosing gaming stutter (PowerShell + WMI/CIM + .NET runspaces; CPU/memory/I/O → CSV).
```
