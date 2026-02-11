$title = 'RTX-4090 Stats'
$Host.UI.RawUI.WindowTitle = $title

# NVML poller for GPU: clock (GHz), temp (C), GPU util (%), VRAM used (%)
# Requires: nvml.dll (NVML)

# Make nvml.dll discoverable if it's in the NVSMI folder (common on standard driver installs)
$nvSmiDir = Join-Path $env:ProgramW6432 'NVIDIA Corporation\NVSMI'
if (Test-Path $nvSmiDir) {
  if ($env:Path -notlike "*$nvSmiDir*") { $env:Path = "$nvSmiDir;$env:Path" }
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class Nvml
{
    private const string NVML_DLL = "nvml.dll";

    public enum nvmlReturn_t : int
    {
        NVML_SUCCESS = 0,
        NVML_ERROR_UNINITIALIZED = 1,
        NVML_ERROR_INVALID_ARGUMENT = 2,
        NVML_ERROR_NOT_SUPPORTED = 3,
        NVML_ERROR_NO_PERMISSION = 4,
        NVML_ERROR_ALREADY_INITIALIZED = 5,
        NVML_ERROR_NOT_FOUND = 6,
        NVML_ERROR_INSUFFICIENT_SIZE = 7,
        NVML_ERROR_INSUFFICIENT_POWER = 8,
        NVML_ERROR_DRIVER_NOT_LOADED = 9,
        NVML_ERROR_TIMEOUT = 10,
        NVML_ERROR_GPU_IS_LOST = 15,
        NVML_ERROR_UNKNOWN = 999
    }

    public enum nvmlTemperatureSensors_t : int
    {
        NVML_TEMPERATURE_GPU = 0
    }

    public enum nvmlClockType_t : int
    {
        NVML_CLOCK_GRAPHICS = 0,
        NVML_CLOCK_SM = 1,
        NVML_CLOCK_MEM = 2,
        NVML_CLOCK_VIDEO = 3
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct nvmlUtilization_t
    {
        public uint gpu;    // GPU utilization (%)
        public uint memory; // Memory controller utilization (%), not VRAM used %
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct nvmlMemory_t
    {
        public ulong total; // bytes
        public ulong free;  // bytes
        public ulong used;  // bytes
    }

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlInit_v2();

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlShutdown();

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlDeviceGetCount_v2(ref uint deviceCount);

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlDeviceGetHandleByIndex_v2(uint index, ref IntPtr device);

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlDeviceGetTemperature(
        IntPtr device, nvmlTemperatureSensors_t sensorType, ref uint temp);

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlDeviceGetClockInfo(
        IntPtr device, nvmlClockType_t type, ref uint clockMHz);

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlDeviceGetUtilizationRates(
        IntPtr device, ref nvmlUtilization_t utilization);

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    public static extern nvmlReturn_t nvmlDeviceGetMemoryInfo(
        IntPtr device, ref nvmlMemory_t memory);

    [DllImport(NVML_DLL, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr nvmlErrorString(nvmlReturn_t result);

    public static string ErrorString(nvmlReturn_t r)
    {
        try { return Marshal.PtrToStringAnsi(nvmlErrorString(r)) ?? r.ToString(); }
        catch { return r.ToString(); }
    }
}
"@

function Assert-NvmlOk {
  param(
    [Parameter(Mandatory=$true)] $Result,
    [Parameter(Mandatory=$true)] [string] $Call
  )
  if ($Result -ne [Nvml+nvmlReturn_t]::NVML_SUCCESS) {
    $msg = [Nvml]::ErrorString($Result)
    throw "$Call failed: $msg"
  }
}

function Set-ThisProcessPriorityAndAffinity {
    param(
        [switch]$Idle,
        [switch]$BelowNormal,
        [string]$AffinityMask
    )

    $p = [System.Diagnostics.Process]::GetCurrentProcess()

    # Priority
    if ($Idle -and $BelowNormal) {
        Write-Warning "Both -Idle and -BelowNormal were specified; using -Idle."
        $BelowNormal = $false
    }

    try {
        if ($Idle)       { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle }
        elseif ($BelowNormal) { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
    } catch {
        Write-Warning "Failed to set process priority: $($_.Exception.Message)"
    }

    # Affinity mask (accept decimal like main.c; also accepts 0x.. if provided)
    if ($AffinityMask) {
        try {
            $maskStr = $AffinityMask.Trim()
            $mask =
                if ($maskStr -match '^0x[0-9a-fA-F]+$') { [UInt64]::Parse($maskStr.Substring(2), [System.Globalization.NumberStyles]::HexNumber) }
                else { [UInt64]$maskStr }

            if ($mask -eq 0) { throw "AffinityMask cannot be 0." }

            # ProcessorAffinity is IntPtr; keep it in-range
            if ([IntPtr]::Size -eq 4 -and $mask -gt [UInt32]::MaxValue) {
                throw "AffinityMask too large for 32-bit PowerShell."
            }

            $p.ProcessorAffinity = [IntPtr]([Int64]$mask)
        } catch {
            Write-Warning "Failed to set affinity mask '$AffinityMask': $($_.Exception.Message)"
        }
    }

    Write-Verbose ("Proc Priority={0}, Affinity=0x{1:X}" -f $p.PriorityClass, $p.ProcessorAffinity.ToInt64())
}
Set-ThisProcessPriorityAndAffinity -Idle -AffinityMask 268369920

# Pick which GPU to monitor (0 = first GPU)
$gpuIndex = 0

Assert-NvmlOk ([Nvml]::nvmlInit_v2()) "nvmlInit_v2"
try {
  [uint32]$count = 0
  Assert-NvmlOk ([Nvml]::nvmlDeviceGetCount_v2([ref]$count)) "nvmlDeviceGetCount_v2"
  if ($count -eq 0) { throw "No NVIDIA GPUs found via NVML." }
  if ($gpuIndex -ge $count) { throw "gpuIndex=$gpuIndex but only $count GPU(s) found." }

  [IntPtr]$dev = [IntPtr]::Zero
  Assert-NvmlOk ([Nvml]::nvmlDeviceGetHandleByIndex_v2([uint32]$gpuIndex, [ref]$dev)) "nvmlDeviceGetHandleByIndex_v2"

  "Timestamp                 GPU_Clock_GHz  Temp_C  GPU_Util_%  VRAM_Used_%"
  while ($true) {
    # Temp
    [uint32]$tempC = 0
    Assert-NvmlOk ([Nvml]::nvmlDeviceGetTemperature($dev, [Nvml+nvmlTemperatureSensors_t]::NVML_TEMPERATURE_GPU, [ref]$tempC)) "nvmlDeviceGetTemperature"

    # Clock (graphics)
    [uint32]$clockMHz = 0
    Assert-NvmlOk ([Nvml]::nvmlDeviceGetClockInfo($dev, [Nvml+nvmlClockType_t]::NVML_CLOCK_GRAPHICS, [ref]$clockMHz)) "nvmlDeviceGetClockInfo(GRAPHICS)"
    $clockGHz = [Math]::Round(($clockMHz / 1000.0), 3)

    # GPU util
    $util = New-Object Nvml+nvmlUtilization_t
    Assert-NvmlOk ([Nvml]::nvmlDeviceGetUtilizationRates($dev, [ref]$util)) "nvmlDeviceGetUtilizationRates"

    # VRAM used %
    $mem = New-Object Nvml+nvmlMemory_t
    Assert-NvmlOk ([Nvml]::nvmlDeviceGetMemoryInfo($dev, [ref]$mem)) "nvmlDeviceGetMemoryInfo"
    $vramPct = if ($mem.total -gt 0) { [Math]::Round((100.0 * $mem.used / $mem.total), 1) } else { 0.0 }

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "{0}   {1,10:N3} GHz     {2,3}°C      {3,3}%        {4,6:N1}%" -f $ts, $clockGHz, $tempC, $util.gpu, $vramPct

    Start-Sleep -Seconds 1
  }
}
finally {
  [void][Nvml]::nvmlShutdown()
}