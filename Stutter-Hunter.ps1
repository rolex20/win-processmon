

<#
.SYNOPSIS
  Stutter-Hunter (C# loop): High-frequency interference detector.

.NOTES
  - Alerts are triggered ONLY by CPU spikes (cpuPercent > CpuSpikeThreshold), same spirit as original.
  - HardFaultThreshold is used ONLY to ANNOTATE WSΔ (WorkingSet delta) on alert lines:
      If WSΔ >= HardFaultThreshold (MB), show "WSΔ: XMB" on that same alert line.
    It does NOT create new alerts and does NOT suppress existing alerts.
  - Per-thread deltas are computed ONLY on LAG lines, and only when thread history exists.
    Thread history is kept for a short retention window after a lag (or always when -ProcessId is used).
#>

<#
OUTPUT FIELD GUIDE (each "LAG DETECTED" line)

Example:
[18:05:44.663] LAG DETECTED: audiodg | CPU: 55.9% | Prio: Unknown | Type: Driver/AV Spike | CPUδ: 62.5ms | K: 100% | TotalCPU: 2.0% (of 28) | WSδ: 120.0MB | TopTID: 8420 Tδ: 38.2ms (K 95%) | HotThr>=5ms: 3

[HH:mm:ss.fff]
  Local timestamp when the alert was printed.

LAG DETECTED: <processName>
  Process that exceeded CpuSpikeThreshold during the last sampling window (default ~100ms).

CPU: <n>%
  "Core-equivalent percent" over the sampling window.
  This is NOT "% of the whole machine". It is normalized to ONE core worth of time:
    CPU% ≈ (CPUδ / wallClockΔ) * 100
  - 100% ≈ used one full core for the whole window
  - 200% ≈ used two full cores for the whole window (multi-threaded burst)
  - 50%  ≈ half a core for the whole window

Prio: <priorityClass>
  Windows priority class (Normal, AboveNormal, High, RealTime, etc).
  "Unknown" means the script couldn't read PriorityClass (often due to access/protected process).

Type: <classification>
  Why the spike is considered suspicious:
  - CPU Spike: exceeded CPU threshold, not AboveNormal/High, and not kernel-heavy
  - Moderate: AboveNormal priority (more likely to preempt other work)
  - CRITICAL (P-Core Theft): High/RealTime priority (can preempt heavily)
  - Driver/AV Spike: kernel-heavy burst (K ratio > 80%), often drivers / AV / OS stack

CPUδ: <n>ms
  CPU time consumed by this process during the sampling window
  (delta of TotalProcessorTime). This value sums across ALL threads/cores.

K: <n>%
  Kernel ratio for the process during the sampling window:
    K% = (delta PrivilegedProcessorTime / CPUδ) * 100
  - High K% (~80–100%) suggests driver/OS/kernel work
  - Low K% suggests mostly user-mode work

TotalCPU: <n>% (of <N>)
  Whole-machine CPU percent equivalent for THIS PROCESS:
    TotalCPU% ≈ CPU% / N
  where N is the number of logical processors (e.g., 28 on an i7-14700K).
  This helps prevent misreading core-equivalent CPU% as "percent of total CPU".

WSδ: <n>MB   (optional)
  Working Set delta (absolute change) across the sampling window, shown only when large.
  This is an annotation-only proxy for memory pressure / trimming / churn.
  It does NOT trigger alerts; alerts are CPU-threshold based only.
  Controlled by HardFaultThreshold (interpreted here as WSδ threshold in MB).

TopTID: <id> Tδ: <n>ms (K <n>%)   (optional)
  The single busiest thread in that process during the sampling window:
  - TopTID is the thread ID (TID)
  - Tδ is that thread's CPU time delta during the window
  - K% is that thread's kernel ratio during the window
  NOTE: Thread deltas are computed only when a lag event occurs (to keep overhead low).
  
Why TopTID: n/a happens
  TopTID is computed from thread CPU deltas, and a delta requires two snapshots:
  snapshot A: thread totals at time t0
  snapshot B: thread totals at time t1
  delta = B − A
  On the first LAG line for a given PID after you start the script (or after its thread history expires), the script can grab the current thread snapshot, but it doesn’t have a previous snapshot to subtract yet, so it prints:
  TopTID: n/a

HotThr>=5ms: <count>   (optional)
  Count of threads in the process whose CPU delta during the window was >= 5ms.
  Higher values generally indicate the spike was spread across multiple threads.
  Low values (especially 1) suggest the spike was dominated by a single thread
  (often more stutter-relevant).

TUNING
- CpuSpikeThreshold controls how noisy the detector is (higher = fewer alerts).
- Rule of thumb for 100ms sampling:
- 5 = extremely chatty (almost any burst)
- 15–25 = usually more “real stutter candidates”
- 40+ = only big hitters


- SampleIntervalMs controls sensitivity (shorter = more sensitive to brief bursts).
- HardFaultThreshold controls when WSδ is displayed (annotation only).
- IncludeSelf switch controls whether the current PowerShell host process is eligible for alerts.
#>



param(
    [string]$GameProcessName = "ForzaHorizon5", # without the .exe
    [int[]]$ProcessId = @(),
	[switch]$IncludeSelf,
    [int]$SampleIntervalMs = 100,
    [double]$CpuSpikeThreshold = 25.0,
    [int]$HardFaultThreshold = 10
)

$ErrorActionPreference = "SilentlyContinue"



if (-not ("StutterHunterRunner" -as [type])) {

$code = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

public class StutterHunterRunner
{
    private class Snapshot
    {
        public double TotalMs;
        public double KernelMs;
        public long WorkingSetBytes;
        public long Tick;
    }

    private class ThreadSnap
    {
        public double TotalMs;
        public double KernelMs;
    }

    private class ThreadHistory
    {
        public Dictionary<int, ThreadSnap> Threads;
        public long LastTick;
    }

    private static volatile bool _stopRequested = false;

    public static void Run(string gameProcessName, int sampleIntervalMs, double cpuSpikeThreshold, int wsDeltaAnnotateThresholdMb, int[] processIds, int selfPid, bool includeSelf)
    {
		_stopRequested = false;
        Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
        {
            e.Cancel = true;
            _stopRequested = true;
        };

        WriteColoredLine("=========================================================", ConsoleColor.Cyan);
        WriteColoredLine("   STUTTER HUNTER (C# loop)", ConsoleColor.Cyan);
        WriteColoredLine("   Scanning for CPU thieves & kernel spikes...", ConsoleColor.Cyan);
        WriteColoredLine("   Ctrl+C to stop", ConsoleColor.DarkGray);
        WriteColoredLine("=========================================================", ConsoleColor.Cyan);

        int logicalCpuCount = Environment.ProcessorCount;

        HashSet<int> filter = null;
        if (processIds != null && processIds.Length > 0)
        {
            filter = new HashSet<int>(processIds);
            WriteColoredLine("PID filter active: " + string.Join(",", processIds), ConsoleColor.Green);
        }

        // Find game PID only when not using PID filter (preserves default behavior)
        int gamePid = -1;
        if (filter == null && !string.IsNullOrWhiteSpace(gameProcessName))
        {
            try
            {
                Process[] games = Process.GetProcessesByName(gameProcessName);
                if (games != null && games.Length > 0)
                {
                    gamePid = games[0].Id;
                    WriteColoredLine(
                        string.Format("Target Game Identified: {0} (PID: {1})", games[0].ProcessName, gamePid),
                        ConsoleColor.Green
                    );
                }
                else
                {
                    WriteColoredLine(
                        string.Format("Warning: Game '{0}' not found. Monitoring ALL processes.", gameProcessName),
                        ConsoleColor.Yellow
                    );
                }

                // Dispose game process handles
                if (games != null)
                {
                    for (int i = 0; i < games.Length; i++)
                    {
                        try { games[i].Dispose(); } catch { }
                    }
                }
            }
            catch
            {
                WriteColoredLine(
                    string.Format("Warning: Unable to resolve game '{0}'. Monitoring ALL processes.", gameProcessName),
                    ConsoleColor.Yellow
                );
            }
        }

        Stopwatch sw = Stopwatch.StartNew();

        Dictionary<int, Snapshot> prev = new Dictionary<int, Snapshot>(1024);
        Dictionary<int, ThreadHistory> threadHist = new Dictionary<int, ThreadHistory>(128);

        // Keep per-thread history briefly after a lag so the *next* lag has accurate thread deltas.
        // Also keeps thread history continuously when -ProcessId is used.
        long threadRetentionTicks = (long)(Stopwatch.Frequency * 2.0); // ~2 seconds

        while (!_stopRequested)
        {
            long loopTick = sw.ElapsedTicks;
            double loopStartMs = sw.Elapsed.TotalMilliseconds;

            Process[] procs;
            try { procs = Process.GetProcesses(); }
            catch { procs = new Process[0]; }

            HashSet<int> currentIds = new HashSet<int>();

            for (int i = 0; i < procs.Length; i++)
            {
                Process p = procs[i];
                int pid;

                try { pid = p.Id; }
                catch { SafeDispose(p); continue; }

                // Always skip Idle/System
                if (pid == 0 || pid == 4) { SafeDispose(p); continue; }
				
				// Default: hide the current PowerShell host process (self)
				if (!includeSelf && pid == selfPid) { SafeDispose(p); continue; }				

                // If user provided PIDs, only monitor those
                if (filter != null && !filter.Contains(pid)) { SafeDispose(p); continue; }

                // Default mode: skip the game itself
                if (filter == null && gamePid != -1 && pid == gamePid) { SafeDispose(p); continue; }

                currentIds.Add(pid);

                double totalMs;
                double kernelMs = 0.0;
                long wsBytes = 0;
                string prioLabel = "Unknown";
                string name = SafeName(p);

                try { totalMs = p.TotalProcessorTime.TotalMilliseconds; }
                catch { SafeDispose(p); continue; }

                try { kernelMs = p.PrivilegedProcessorTime.TotalMilliseconds; } catch { }
                try { wsBytes = p.WorkingSet64; } catch { }
                try { prioLabel = p.PriorityClass.ToString(); } catch { }

                Snapshot old;
                bool hadOld = prev.TryGetValue(pid, out old);

                // Thread tracking state (lazy)
                ThreadHistory th;
                threadHist.TryGetValue(pid, out th);

                bool isFilterPid = (filter != null); // because we already continued non-filter pids above
                bool trackedRecently = (th != null && (loopTick - th.LastTick) <= threadRetentionTicks);
                bool shouldUpdateThreadsThisSample = isFilterPid || trackedRecently;

                if (hadOld)
                {
                    double dtMs = TicksToMs(loopTick - old.Tick, Stopwatch.Frequency);
                    if (dtMs > 0.0)
                    {
                        double cpuDeltaMs = totalMs - old.TotalMs;
                        double cpuPercent = (cpuDeltaMs / dtMs) * 100.0; // "core-equivalent %"

                        double kernelDeltaMs = kernelMs - old.KernelMs;
                        double kernelRatio = (cpuDeltaMs > 0.0) ? (kernelDeltaMs / cpuDeltaMs) : 0.0;

                        // Annotation-only: WS delta shown only if large enough
                        double wsDeltaMb = Math.Abs(wsBytes - old.WorkingSetBytes) / (1024.0 * 1024.0);

                        // Trigger stays CPU-only (same "spirit")
                        bool isLag = (cpuPercent > cpuSpikeThreshold);

                        // For lag lines, we may want thread info even if we weren't tracking yet
                        bool wantThreadsNow = shouldUpdateThreadsThisSample || isLag;

                        Dictionary<int, ThreadSnap> oldThreads = (th != null) ? th.Threads : null;
                        Dictionary<int, ThreadSnap> newThreads = null;

                        if (wantThreadsNow)
                        {
                            newThreads = TrySnapshotThreads(p);

                            if (newThreads != null)
                            {
                                if (th == null)
                                {
                                    th = new ThreadHistory();
                                    threadHist[pid] = th;
                                }
                                th.Threads = newThreads;
                                th.LastTick = loopTick;
                            }
                            else
                            {
                                // Still bump LastTick if we are tracking; avoids immediate purge-flapping
                                if (th != null && shouldUpdateThreadsThisSample)
                                    th.LastTick = loopTick;
                            }
                        }

                        if (isLag)
                        {
                            string danger = "CPU Spike";
                            ConsoleColor color = ConsoleColor.Gray;

                            if (prioLabel == "High" || prioLabel == "RealTime")
                            {
                                danger = "CRITICAL (P-Core Theft)";
                                color = ConsoleColor.Red;
                            }
                            else if (prioLabel == "AboveNormal")
                            {
                                danger = "Moderate";
                                color = ConsoleColor.Yellow;
                            }
                            else if (kernelRatio > 0.8)
                            {
                                danger = "Driver/AV Spike";
                                color = ConsoleColor.Magenta;
                            }

                            string ts = DateTime.Now.ToString("HH:mm:ss.fff");

                            double totalCpuPercent = cpuPercent / (double)logicalCpuCount;

                            // Always show CPUΔ, kernel ratio, and normalized TotalCPU on LAG lines
                            string details = string.Format(
                                " | CPU\u0394: {0,6:N1}ms | K: {1,3:N0}% | TotalCPU: {2,5:N1}% (of {3})",
                                cpuDeltaMs,
                                kernelRatio * 100.0,
                                totalCpuPercent,
                                logicalCpuCount
                            );

                            // Show WSΔ only if it exceeds threshold (MB); does not affect triggering
                            if (wsDeltaAnnotateThresholdMb > 0 && wsDeltaMb >= wsDeltaAnnotateThresholdMb)
                            {
                                details += string.Format(" | WS\u0394: {0,6:N1}MB", wsDeltaMb);
                            }

                            // Per-thread deltas (only meaningful if we had a prior thread snapshot)
                            details += BuildThreadDetails(oldThreads, newThreads);
							
							string shortName = name.Length > 10 ? name.Substring(0, 10) : name;
                            string msg = string.Format(
                                "[{0}] {1,-10} | CPU: {2,5:N1}% | Prio: {3,-10} | Type: {4}{5}",
                                ts, shortName, cpuPercent, prioLabel, danger, details
                            );

                            WriteColoredLine(msg, color);

                            if (color == ConsoleColor.Red)
                            {
                                try { Console.Beep(800, 100); } catch { }
                            }

                            // Ensure we keep tracking threads for a short window after a lag
                            if (th != null)
                                th.LastTick = loopTick;
                        }
                    }
                }
                else
                {
                    // No previous process snapshot yet. Still keep per-thread history for filtered PIDs
                    // so the next sample can compute thread deltas accurately.
                    if (shouldUpdateThreadsThisSample)
                    {
                        Dictionary<int, ThreadSnap> snap = TrySnapshotThreads(p);
                        if (snap != null)
                        {
                            if (th == null)
                            {
                                th = new ThreadHistory();
                                threadHist[pid] = th;
                            }
                            th.Threads = snap;
                            th.LastTick = loopTick;
                        }
                        else
                        {
                            if (th != null)
                                th.LastTick = loopTick;
                        }
                    }
                }

                // Update process snapshot
                prev[pid] = new Snapshot
                {
                    TotalMs = totalMs,
                    KernelMs = kernelMs,
                    WorkingSetBytes = wsBytes,
                    Tick = loopTick
                };

                SafeDispose(p);
            }
			
            // If a PID filter is active, processes were successfully queried, but no target PIDs are alive
            if (filter != null && procs.Length > 0 && currentIds.Count == 0)
            {
                WriteColoredLine("All monitored PIDs are dead. Auto-stopping...", ConsoleColor.DarkGray);
                _stopRequested = true;
                continue; 
            }			

            // Cleanup snapshots for exited processes
            if (prev.Count > 0)
            {
                List<int> keys = new List<int>(prev.Keys);
                for (int k = 0; k < keys.Count; k++)
                {
                    int id = keys[k];
                    if (!currentIds.Contains(id))
                        prev.Remove(id);
                }
            }

            // Cleanup thread history:
            // - remove entries for exited processes
            // - if not PID-filter mode, prune old histories beyond retention window
            if (threadHist.Count > 0)
            {
                List<int> keys = new List<int>(threadHist.Keys);
                for (int k = 0; k < keys.Count; k++)
                {
                    int id = keys[k];

                    ThreadHistory h;
                    if (!threadHist.TryGetValue(id, out h))
                        continue;

                    bool exited = !currentIds.Contains(id);
                    bool expired = (filter == null) && (h != null) && ((loopTick - h.LastTick) > threadRetentionTicks);

                    if (exited || expired)
                        threadHist.Remove(id);
                }
            }

            // Sleep to maintain target interval
            double elapsedMs = sw.Elapsed.TotalMilliseconds - loopStartMs;
            int sleepMs = (int)Math.Round(sampleIntervalMs - elapsedMs);
            if (sleepMs > 0)
                Thread.Sleep(sleepMs);
        }

        WriteColoredLine("Stopping Stutter-Hunter...", ConsoleColor.DarkGray);
    }

    private static string BuildThreadDetails(Dictionary<int, ThreadSnap> oldThreads, Dictionary<int, ThreadSnap> newThreads)
    {
        // Only append on LAG lines; caller always appends this return string.
        // If we don't have both snapshots, we can't compute a meaningful delta.
        if (newThreads == null)
            return " | Threads: n/a";

        if (oldThreads == null)
            return " | TopTID: n/a";

        int topTid = -1;
        double topDeltaMs = 0.0;
        double topKernelRatio = 0.0;
        int hotCount = 0;

        const double hotThresholdMs = 5.0;

        foreach (KeyValuePair<int, ThreadSnap> kv in newThreads)
        {
            int tid = kv.Key;
            ThreadSnap cur = kv.Value;

            ThreadSnap old;
            if (!oldThreads.TryGetValue(tid, out old))
                continue;

            double dTotal = cur.TotalMs - old.TotalMs;
            if (dTotal <= 0.0)
                continue;

            if (dTotal >= hotThresholdMs)
                hotCount++;

            if (dTotal > topDeltaMs)
            {
                double dKernel = cur.KernelMs - old.KernelMs;
                topDeltaMs = dTotal;
                topTid = tid;
                topKernelRatio = (dTotal > 0.0) ? (dKernel / dTotal) : 0.0;
            }
        }

        if (topTid == -1)
            return " | TopTID: n/a";

        return string.Format(
            " | TopTID: {0} T\u0394: {1,5:N1}ms (K {2,3:N0}%) | HotThr>=5ms: {3}",
            topTid,
            topDeltaMs,
            topKernelRatio * 100.0,
            hotCount
        );
    }

    private static Dictionary<int, ThreadSnap> TrySnapshotThreads(Process p)
    {
        try
        {
            ProcessThreadCollection threads = p.Threads;
            if (threads == null)
                return null;

            Dictionary<int, ThreadSnap> snap = new Dictionary<int, ThreadSnap>(threads.Count);

            for (int i = 0; i < threads.Count; i++)
            {
                ProcessThread t = threads[i];
                int tid;

                try { tid = t.Id; }
                catch { continue; }

                double totalMs;
                double kernelMs = 0.0;

                try { totalMs = t.TotalProcessorTime.TotalMilliseconds; }
                catch { continue; }

                try { kernelMs = t.PrivilegedProcessorTime.TotalMilliseconds; } catch { }

                snap[tid] = new ThreadSnap { TotalMs = totalMs, KernelMs = kernelMs };
            }

            return snap;
        }
        catch
        {
            return null;
        }
    }

    private static double TicksToMs(long ticks, long freq)
    {
        return (ticks * 1000.0) / (double)freq;
    }

    private static string SafeName(Process p)
    {
        try { return p.ProcessName; } catch { return "<unknown>"; }
    }

    private static void SafeDispose(Process p)
    {
        try { p.Dispose(); } catch { }
    }

    private static void WriteColoredLine(string msg, ConsoleColor color)
    {
        ConsoleColor old = Console.ForegroundColor;
        try
        {
            Console.ForegroundColor = color;
            Console.WriteLine(msg);
        }
        finally
        {
            Console.ForegroundColor = old;
        }
    }
}
'@

    Add-Type -TypeDefinition $code -Language CSharp
}

[StutterHunterRunner]::Run(
    $GameProcessName,
    $SampleIntervalMs,
    $CpuSpikeThreshold,
    $HardFaultThreshold,
    $ProcessId,
    $PID,
    [bool]$IncludeSelf
)

Write-Host "Press Ctrl+C to exit" 
Start-Sleep 3600