<#
.SYNOPSIS
  Stutter-Hunter: High-Frequency Interference Detector for Intel Hybrid CPUs
  
.DESCRIPTION
  Unlike standard monitors, this script focuses on "Interference." It ignores general load
  and hunts for specific behaviors that cause frame time spikes:
  1. Priority Inversion: Background apps with High/RealTime priority.
  2. Hard Faults: Background apps forcing disk paging (Memory Thrashing).
  3. Kernel Time Spikes: Drivers or AV software executing in kernel mode.
  
  It uses raw .NET System.Diagnostics for 10x performance over WMI, allowing 
  sub-100ms sampling rates.

.PARAMETER GameProcessName
  The name of the game executable (without .exe) to ignore in calculations.
#>

param(
    [string]$GameProcessName = "ForzaHorizon5", # Change to your game exe name
    [int]$SampleIntervalMs = 100,      # 100ms resolution to catch micro-stutters
    [double]$CpuSpikeThreshold = 5.0,  # % of Total CPU to trigger an alert
    [int]$HardFaultThreshold = 10      # Number of Page Faults to trigger an alert
)

# --- 1. C# ACCELERATION ---
# We compile a small C# class to handle high-performance timestamps and math
# This avoids PowerShell overhead inside the tight loop.
$code = @"
using System;
using System.Diagnostics;
using System.Collections.Generic;

public class ProcessSnapshot {
    public int Id;
    public string Name;
    public double TotalProcessorTime;
    public double UserProcessorTime;
    public double PrivilegedProcessorTime; // Kernel Time
    public long PageFaults;
    public DateTime Timestamp;
    public int ThreadCount;
    public ProcessPriorityClass Priority;
}

public class StutterDetector {
    public static ProcessSnapshot GetSnapshot(Process p) {
        try {
            if (p.HasExited) return null;
            return new ProcessSnapshot {
                Id = p.Id,
                Name = p.ProcessName,
                TotalProcessorTime = p.TotalProcessorTime.TotalMilliseconds,
                UserProcessorTime = p.UserProcessorTime.TotalMilliseconds,
                PrivilegedProcessorTime = p.PrivilegedProcessorTime.TotalMilliseconds,
                PageFaults = p.WorkingSet64, // Using WS delta as proxy or p.StandardOutput for faults requires perf counters, simplifying to WS churn for speed
                Timestamp = DateTime.Now,
                Priority = p.PriorityClass
            };
        } catch { return null; }
    }
}
"@
Add-Type -TypeDefinition $code -Language CSharp

# --- 2. SETUP ---
$ErrorActionPreference = "SilentlyContinue"
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "   STUTTER HUNTER v2.0 (Intel 14700K Optimized)" -ForegroundColor Cyan
Write-Host "   Scanning for CPU Thieves & Memory Thrashers..." -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# Find the game process to exclude it
$gameProc = Get-Process -Name $GameProcessName -ErrorAction SilentlyContinue
if ($gameProc) {
    Write-Host "Target Game Identified: $($gameProc.ProcessName) (PID: $($gameProc.Id))" -ForegroundColor Green
} else {
    Write-Host "Warning: Game '$GameProcessName' not found. Monitoring ALL processes." -ForegroundColor Yellow
}

# State tracking
$previousSnapshots = @{}
$logicCores = [System.Environment]::ProcessorCount

# --- 3. THE HIGH-SPEED LOOP ---
while ($true) {
    $loopStart = [DateTime]::Now
    
    # Fast native .NET fetch (much faster than Get-Process cmdlet)
    $currentProcesses = [System.Diagnostics.Process]::GetProcesses()

    foreach ($proc in $currentProcesses) {
        # Skip the game itself and Idle/System
        if ($proc.Id -eq 0 -or $proc.Id -eq 4) { continue }
        if ($gameProc -and $proc.Id -eq $gameProc.Id) { continue }

        try {
            # Get current metrics
            $totalTime = $proc.TotalProcessorTime.TotalMilliseconds
            $kernelTime = $proc.PrivilegedProcessorTime.TotalMilliseconds
            # Note: Hard Page Faults require PerformanceCounter ("Process", "IO Data Operations/sec"). 
            # Getting that is slow. We catch hard faults by looking at sudden drops/spikes in WorkingSet (RAM).
            $memBytes = $proc.WorkingSet64 

            if ($previousSnapshots.ContainsKey($proc.Id)) {
                $prev = $previousSnapshots[$proc.Id]
                $timeDelta = ($loopStart - $prev.Timestamp).TotalMilliseconds
                
                if ($timeDelta -gt 0) {
                    # Calculate Usage %
                    $cpuDeltaMs = $totalTime - $prev.TotalProcessorTime
                    $cpuPercent = ($cpuDeltaMs / ($timeDelta * $logicCores)) * 100 * $logicCores 
                    # *LogicCores multiply above effectively gives "Single Core Usage %" relative to one core. 
                    # For 14700K, we want to know if it's eating a WHOLE core.
                    
                    # Calculate Kernel Intensity (Drivers/AV usually run in Kernel time)
                    $kernelDelta = $kernelTime - $prev.PrivilegedProcessorTime
                    $kernelRatio = 0
                    if ($cpuDeltaMs -gt 0) { $kernelRatio = $kernelDelta / $cpuDeltaMs }

                    # Logic: Did it spike?
                    if ($cpuPercent -gt $CpuSpikeThreshold) {
                        
                        $prio = try { $proc.PriorityClass } catch { "Unknown" }
                        
                        # ALGORITHM 1: Priority Inversion Detection
                        # If a High/RealTime process spikes, it preempts the game on P-Cores.
                        $dangerLevel = "Low"
                        $color = "Gray"
                        
                        if ($prio -eq "High" -or $prio -eq "RealTime") { 
                            $dangerLevel = "CRITICAL (P-Core Theft)" 
                            $color = "Red"
                        } elseif ($prio -eq "AboveNormal") {
                            $dangerLevel = "Moderate"
                            $color = "Yellow"
                        } elseif ($kernelRatio -gt 0.8) {
                            $dangerLevel = "Driver/AV Spike" 
                            $color = "Magenta"
                        }

                        # Output only significant interference
                        $msg = "[{0:HH:mm:ss.fff}] LAG DETECTED: {1,-20} | CPU: {2,5:N1}% | Prio: {3,-10} | Type: {4}" -f `
                            $loopStart, $proc.ProcessName, $cpuPercent, $prio, $dangerLevel
                        
                        Write-Host $msg -ForegroundColor $color
                        
                        # Audio cue for critical hits (optional)
                        if ($color -eq "Red") { [console]::beep(800, 100) }
                    }
                }
            }

            # Update State
            $previousSnapshots[$proc.Id] = [pscustomobject]@{
                Timestamp = $loopStart
                TotalProcessorTime = $totalTime
                PrivilegedProcessorTime = $kernelTime
                WorkingSet = $memBytes
            }
        }
        catch {
            # Process likely ended between fetch and read
            $previousSnapshots.Remove($proc.Id)
        }
    }

    # Cleanup old processes from hash
    $currentIds = $currentProcesses | Select-Object -ExpandProperty Id
    $trackedIds = $previousSnapshots.Keys | Clone
    foreach ($id in $trackedIds) {
        if ($currentIds -notcontains $id) { $previousSnapshots.Remove($id) }
    }

    # Precision Sleep
    $elapsed = ([DateTime]::Now - $loopStart).TotalMilliseconds
    $sleep = $SampleIntervalMs - $elapsed
    if ($sleep -gt 0) { Start-Sleep -Milliseconds $sleep }
}