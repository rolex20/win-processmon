param(
  [int]$Iterations = 20,
  [int]$SleepMs    = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$cs = @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;

public static class HybridQosDemo
{
    private static readonly object _lock = new object();

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESSOR_NUMBER
    {
        public ushort Group;
        public byte Number;
        public byte Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct THREAD_POWER_THROTTLING_STATE
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    public sealed class CpuSetEntry
    {
        public uint Id;
        public ushort Group;
        public byte LogicalProcessorIndex;
        public byte CoreIndex;
        public byte EfficiencyClass;

        public byte Flags; // AllFlags
        public bool Parked;
        public bool Allocated;
        public bool AllocatedToTargetProcess;
        public bool RealTime;

        public override string ToString()
        {
            return string.Format(
                "Id={0} Group={1} LPIndex={2} CoreIndex={3} EffClass={4} Flags=0x{5:X2} Parked={6} Allocated={7} AllocToThisProc={8} RealTime={9}",
                Id, Group, LogicalProcessorIndex, CoreIndex, EfficiencyClass, Flags,
                Parked, Allocated, AllocatedToTargetProcess, RealTime
            );
        }
    }

    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const int ERROR_INVALID_PARAMETER   = 87;

    // Thread priorities
    private const int THREAD_PRIORITY_NORMAL       = 0;
    private const int THREAD_PRIORITY_BELOW_NORMAL = -1;

    // Power throttling constants (from headers / docs)
    private const uint THREAD_POWER_THROTTLING_CURRENT_VERSION = 1;
    private const uint THREAD_POWER_THROTTLING_EXECUTION_SPEED = 1;

    // ThreadInformationClass numeric values:
    // Win11 (build 22000+) headers insert extra enum values; ThreadPowerThrottling is typically 3 there.
    // Older Win10 headers historically had ThreadPowerThrottling as 1.
    // We'll try Win11 first, then fallback to Win10 if we see ERROR_INVALID_PARAMETER.
    private const int TIC_THREAD_POWER_THROTTLING_WIN11 = 3;
    private const int TIC_THREAD_POWER_THROTTLING_WIN10 = 1;

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentThread();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemCpuSetInformation(
        IntPtr Information,
        uint BufferLength,
        out uint ReturnedLength,
        IntPtr Process,
        uint Flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetThreadSelectedCpuSets(
        IntPtr Thread,
        uint[] CpuSetIds,
        uint CpuSetIdCount);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetThreadInformation(
        IntPtr hThread,
        int ThreadInformationClass,
        ref THREAD_POWER_THROTTLING_STATE ThreadInformation,
        uint ThreadInformationSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetThreadPriority(
        IntPtr hThread,
        int nPriority);

    [DllImport("kernel32.dll")]
    private static extern void GetCurrentProcessorNumberEx(out PROCESSOR_NUMBER ProcNumber);

    private static void WriteLine(string s)
    {
        lock (_lock)
        {
            Console.WriteLine(s);
        }
    }

    private static string Win32Error(int errorCode)
    {
        return new Win32Exception(errorCode).Message;
    }

    private static void ThrowLastWin32(string api)
    {
        int err = Marshal.GetLastWin32Error();
        throw new InvalidOperationException(
            string.Format("{0} failed. Win32Error={1} (0x{1:X}) {2}", api, err, Win32Error(err))
        );
    }

    public static bool IsRunningAsAdmin()
    {
        try
        {
            var id = WindowsIdentity.GetCurrent();
            var p  = new WindowsPrincipal(id);
            return p.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    public static CpuSetEntry[] QueryCpuSets(out byte minEff, out byte maxEff)
    {
        IntPtr process = GetCurrentProcess();

        // Size query
        uint needed = 0;
        bool ok = GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, process, 0);
        if (!ok)
        {
            int err = Marshal.GetLastWin32Error();
            if (err != ERROR_INSUFFICIENT_BUFFER)
            {
                throw new InvalidOperationException(
                    string.Format("GetSystemCpuSetInformation(size query) failed. Win32Error={0} (0x{0:X}) {1}", err, Win32Error(err))
                );
            }
        }

        if (needed == 0)
        {
            minEff = maxEff = 0;
            return new CpuSetEntry[0];
        }

        IntPtr buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            uint returned = 0;
            ok = GetSystemCpuSetInformation(buffer, needed, out returned, process, 0);
            if (!ok)
                ThrowLastWin32("GetSystemCpuSetInformation(data)");

            var list = new List<CpuSetEntry>(64);
            byte localMin = 255;
            byte localMax = 0;

            long cur = buffer.ToInt64();
            long end = cur + returned;

            while (cur < end)
            {
                IntPtr p = new IntPtr(cur);
                int size = Marshal.ReadInt32(p);
                if (size <= 0) break;

                // CPU_SET_INFORMATION_TYPE at offset 4 (DWORD)
                int type = Marshal.ReadInt32(p, 4);

                // CpuSetInformation == 0 (currently the only documented type)
                if (type == 0)
                {
                    // Offsets per SYSTEM_CPU_SET_INFORMATION layout
                    uint id        = (uint)Marshal.ReadInt32(p, 8);
                    ushort group   = (ushort)Marshal.ReadInt16(p, 12);
                    byte lpIndex   = Marshal.ReadByte(p, 14);
                    byte coreIndex = Marshal.ReadByte(p, 15);
                    byte effClass  = Marshal.ReadByte(p, 18);
                    byte allFlags  = Marshal.ReadByte(p, 19);

                    bool parked          = (allFlags & 0x01) != 0;
                    bool allocated       = (allFlags & 0x02) != 0;
                    bool allocToThisProc = (allFlags & 0x04) != 0;
                    bool realtime        = (allFlags & 0x08) != 0;

                    var e = new CpuSetEntry
                    {
                        Id = id,
                        Group = group,
                        LogicalProcessorIndex = lpIndex,
                        CoreIndex = coreIndex,
                        EfficiencyClass = effClass,
                        Flags = allFlags,
                        Parked = parked,
                        Allocated = allocated,
                        AllocatedToTargetProcess = allocToThisProc,
                        RealTime = realtime
                    };

                    list.Add(e);

                    if (effClass < localMin) localMin = effClass;
                    if (effClass > localMax) localMax = effClass;
                }

                cur += size;
            }

            minEff = (list.Count == 0) ? (byte)0 : localMin;
            maxEff = (list.Count == 0) ? (byte)0 : localMax;
            return list.ToArray();
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static CpuSetEntry FindCpuSet(CpuSetEntry[] snapshot, ushort group, byte logicalProcessorIndex)
    {
        if (snapshot == null) return null;
        for (int i = 0; i < snapshot.Length; i++)
        {
            var e = snapshot[i];
            if (e.Group == group && e.LogicalProcessorIndex == logicalProcessorIndex)
                return e;
        }
        return null;
    }

    private static string EffLabel(byte eff, byte minEff, byte maxEff)
    {
        if (minEff == maxEff) return "single-class (no hetero distinction)";
        if (eff == minEff) return "most-efficient class (likely E-cores)";
        if (eff == maxEff) return "fastest class (likely P-cores)";
        return "middle class";
    }

    public static void SetEcoQoSForCurrentThread(bool enable)
    {
        var s = new THREAD_POWER_THROTTLING_STATE
        {
            Version = THREAD_POWER_THROTTLING_CURRENT_VERSION,
            ControlMask = THREAD_POWER_THROTTLING_EXECUTION_SPEED,
            StateMask = enable ? THREAD_POWER_THROTTLING_EXECUTION_SPEED : 0
        };

        IntPtr hThread = GetCurrentThread();
        uint cb = (uint)Marshal.SizeOf(typeof(THREAD_POWER_THROTTLING_STATE));

        bool ok = SetThreadInformation(hThread, TIC_THREAD_POWER_THROTTLING_WIN11, ref s, cb);
        if (!ok)
        {
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_INVALID_PARAMETER)
            {
                ok = SetThreadInformation(hThread, TIC_THREAD_POWER_THROTTLING_WIN10, ref s, cb);
                if (!ok) ThrowLastWin32("SetThreadInformation(ThreadPowerThrottling,fallback)");
                WriteLine(string.Format("[info] EcoQoS: used Win10 ThreadInformationClass value ({0}).", TIC_THREAD_POWER_THROTTLING_WIN10));
            }
            else
            {
                throw new InvalidOperationException(
                    string.Format("SetThreadInformation(ThreadPowerThrottling) failed. Win32Error={0} (0x{0:X}) {1}", err, Win32Error(err))
                );
            }
        }
    }

    public static void SetCpuSetsForCurrentThread(uint[] cpuSetIds)
    {
        IntPtr hThread = GetCurrentThread();
        uint count = (cpuSetIds == null) ? 0u : (uint)cpuSetIds.Length;

        bool ok = SetThreadSelectedCpuSets(hThread, cpuSetIds, count);
        if (!ok) ThrowLastWin32("SetThreadSelectedCpuSets");
    }

    public static void SetBelowNormalPriorityForCurrentThread()
    {
        IntPtr hThread = GetCurrentThread();
        bool ok = SetThreadPriority(hThread, THREAD_PRIORITY_BELOW_NORMAL);
        if (!ok) ThrowLastWin32("SetThreadPriority(BELOW_NORMAL)");
    }

    public static void Run(int iterations, int sleepMs)
    {
        WriteLine("=== HybridQosDemo (PowerShell + Add-Type C#) ===");
        WriteLine("Running as admin: " + (IsRunningAsAdmin() ? "YES" : "NO"));
        WriteLine("");

        byte minEff, maxEff;
        CpuSetEntry[] snap = QueryCpuSets(out minEff, out maxEff);

        WriteLine(string.Format("CPU Sets found: {0}", snap.Length));
        WriteLine(string.Format("EfficiencyClass: min={0}, max={1}", minEff, maxEff));
        WriteLine("");

        for (int i = 0; i < snap.Length; i++)
        {
            WriteLine("  " + snap[i].ToString());
        }

        // Build ID lists:
        // Skip CPU sets that are allocated but not allocated to this process, to avoid "ignored assignments".
        var eIds = new List<uint>();
        var pIds = new List<uint>();

        for (int i = 0; i < snap.Length; i++)
        {
            var e = snap[i];
            if (e.Allocated && !e.AllocatedToTargetProcess) continue;

            if (e.EfficiencyClass == minEff) eIds.Add(e.Id);
            if (e.EfficiencyClass == maxEff) pIds.Add(e.Id);
        }

        WriteLine("");
        WriteLine(string.Format("Allowed most-efficient CpuSetIds: {0}", eIds.Count));
        WriteLine(string.Format("Allowed fastest CpuSetIds:       {0}", pIds.Count));
        WriteLine("");

        var workers = new[]
        {
            new WorkerConfig("NORMAL",         snap, minEff, maxEff, eco:false, below:false, cpuSetIds:null,          iterations:iterations, sleepMs:sleepMs),
            new WorkerConfig("ECOQOS_ONLY",    snap, minEff, maxEff, eco:true,  below:true,  cpuSetIds:null,          iterations:iterations, sleepMs:sleepMs),
            new WorkerConfig("CPUSET_E_CLASS", snap, minEff, maxEff, eco:true,  below:true,  cpuSetIds:eIds.ToArray(),iterations:iterations, sleepMs:sleepMs),
            new WorkerConfig("CPUSET_P_CLASS", snap, minEff, maxEff, eco:false, below:false, cpuSetIds:pIds.ToArray(),iterations:iterations, sleepMs:sleepMs),
        };

        var threads = new Thread[workers.Length];
        for (int i = 0; i < workers.Length; i++)
        {
            threads[i] = new Thread(WorkerMain);
            threads[i].IsBackground = false;
            threads[i].Start(workers[i]);
        }

        for (int i = 0; i < threads.Length; i++)
        {
            threads[i].Join();
        }

        WriteLine("\nDone.");
    }

    private sealed class WorkerConfig
    {
        public readonly string Name;
        public readonly CpuSetEntry[] Snapshot;
        public readonly byte MinEff;
        public readonly byte MaxEff;
        public readonly bool EcoQoS;
        public readonly bool BelowNormalPriority;
        public readonly uint[] CpuSetIds;
        public readonly int Iterations;
        public readonly int SleepMs;

        public WorkerConfig(string name, CpuSetEntry[] snapshot, byte minEff, byte maxEff, bool eco, bool below, uint[] cpuSetIds, int iterations, int sleepMs)
        {
            Name = name;
            Snapshot = snapshot;
            MinEff = minEff;
            MaxEff = maxEff;
            EcoQoS = eco;
            BelowNormalPriority = below;
            CpuSetIds = cpuSetIds;
            Iterations = iterations;
            SleepMs = sleepMs;
        }
    }

    private static void WorkerMain(object state)
    {
        var cfg = (WorkerConfig)state;

        try
        {
            if (cfg.BelowNormalPriority)
                SetBelowNormalPriorityForCurrentThread();

            if (cfg.EcoQoS)
                SetEcoQoSForCurrentThread(true);

            if (cfg.CpuSetIds != null && cfg.CpuSetIds.Length > 0)
                SetCpuSetsForCurrentThread(cfg.CpuSetIds);

            for (int i = 0; i < cfg.Iterations; i++)
            {
                PROCESSOR_NUMBER pn;
                GetCurrentProcessorNumberEx(out pn);

                var entry = FindCpuSet(cfg.Snapshot, pn.Group, pn.Number);

                if (entry != null)
                {
                    WriteLine(string.Format("[{0}] G{1}:CPU{2}  CpuSetId={3}  EffClass={4} ({5})  Flags=0x{6:X2}",
                        cfg.Name, pn.Group, pn.Number, entry.Id, entry.EfficiencyClass,
                        EffLabel(entry.EfficiencyClass, cfg.MinEff, cfg.MaxEff),
                        entry.Flags));
                }
                else
                {
                    WriteLine(string.Format("[{0}] G{1}:CPU{2}  (no matching CpuSet entry)", cfg.Name, pn.Group, pn.Number));
                }

                Thread.Sleep(cfg.SleepMs);
            }
        }
        catch (Exception ex)
        {
            WriteLine(string.Format("[{0}] ERROR: {1}", cfg.Name, ex.ToString()));
        }
    }
}
"@

Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop

[HybridQosDemo]::Run($Iterations, $SleepMs)
