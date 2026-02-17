// hybrid_qos_demo.c
// Demonstrates Intel-recommended Windows approach for hybrid CPUs:
// 1) EcoQoS (PowerThrottling) via SetThreadInformation(ThreadPowerThrottling)
// 2) CPU Sets (soft affinity) via GetSystemCpuSetInformation + SetThreadSelectedCpuSets
//
// Build (MSVC x64):
//   cl /nologo /W4 /O2 hybrid_qos_demo.c
//
// Run:
//   hybrid_qos_demo.exe

#define _WIN32_WINNT 0x0A00
#define NOMINMAX

#include <windows.h>
#include <processthreadsapi.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdarg.h>
#include <process.h>

typedef struct CpuSetRecord {
    ULONG id;
    WORD  group;
    BYTE  lpIndex;          // group-relative logical processor index
    BYTE  coreIndex;        // cores that share execution resources have same coreIndex
    BYTE  efficiencyClass;  // higher = faster but less power-efficient
    BYTE  parked;           // 1 if parked
    BYTE  allocated;        // 1 if reserved/allocated
} CpuSetRecord;

typedef struct CpuSetSnapshot {
    CpuSetRecord* records;
    size_t count;

    BYTE minEff; // "most efficient class" (lowest)
    BYTE maxEff; // "fastest class" (highest)

    ULONG* ids_most_efficient;
    ULONG  ids_most_efficient_count;

    ULONG* ids_fastest;
    ULONG  ids_fastest_count;
} CpuSetSnapshot;

static CRITICAL_SECTION g_logLock;

static void logf(const char* fmt, ...) {
    EnterCriticalSection(&g_logLock);
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    fflush(stdout);
    LeaveCriticalSection(&g_logLock);
}

static void print_last_error(const char* api) {
    DWORD err = GetLastError();
    char* msg = NULL;

    FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
        NULL,
        err,
        MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        (LPSTR)&msg,
        0,
        NULL
    );

    logf("[!] %s failed. GetLastError=%lu (%s)\n", api, (unsigned long)err, msg ? msg : "no message");
    if (msg) LocalFree(msg);
}

static void free_snapshot(CpuSetSnapshot* s) {
    if (!s) return;
    free(s->records);
    free(s->ids_most_efficient);
    free(s->ids_fastest);
    ZeroMemory(s, sizeof(*s));
}

static bool build_cpu_set_snapshot(CpuSetSnapshot* out) {
    if (!out) return false;
    ZeroMemory(out, sizeof(*out));

    ULONG needed = 0;
    BOOL ok = GetSystemCpuSetInformation(NULL, 0, &needed, GetCurrentProcess(), 0);
    if (!ok) {
        DWORD err = GetLastError();
        if (err != ERROR_INSUFFICIENT_BUFFER) {
            print_last_error("GetSystemCpuSetInformation(size query)");
            return false;
        }
    }
    if (needed == 0) {
        logf("[!] No CPU Sets returned (needed=0).\n");
        return false;
    }

    uint8_t* buffer = (uint8_t*)malloc(needed);
    if (!buffer) {
        logf("[!] malloc(%lu) failed.\n", (unsigned long)needed);
        return false;
    }

    ULONG returned = 0;
    ok = GetSystemCpuSetInformation((PSYSTEM_CPU_SET_INFORMATION)buffer, needed, &returned, GetCurrentProcess(), 0);
    if (!ok) {
        print_last_error("GetSystemCpuSetInformation(data)");
        free(buffer);
        return false;
    }

    // First pass: count CpuSetInformation entries
    size_t count = 0;
    uint8_t* p = buffer;
    uint8_t* end = buffer + returned;

    while (p < end) {
        PSYSTEM_CPU_SET_INFORMATION info = (PSYSTEM_CPU_SET_INFORMATION)p;
        if (info->Size == 0) break;

        if (info->Type == CpuSetInformation) {
            count++;
        }
        p += info->Size;
    }

    if (count == 0) {
        logf("[!] No CpuSetInformation entries found.\n");
        free(buffer);
        return false;
    }

    CpuSetRecord* records = (CpuSetRecord*)calloc(count, sizeof(CpuSetRecord));
    if (!records) {
        logf("[!] calloc(%zu) failed.\n", count);
        free(buffer);
        return false;
    }

    // Second pass: fill records + compute min/max efficiency class
    BYTE minEff = 0xFF;
    BYTE maxEff = 0x00;

    size_t idx = 0;
    p = buffer;

    while (p < end && idx < count) {
        PSYSTEM_CPU_SET_INFORMATION info = (PSYSTEM_CPU_SET_INFORMATION)p;
        if (info->Size == 0) break;

        if (info->Type == CpuSetInformation) {
            CpuSetRecord r;
            r.id              = info->CpuSet.Id;
            r.group           = info->CpuSet.Group;
            r.lpIndex         = info->CpuSet.LogicalProcessorIndex;
            r.coreIndex       = info->CpuSet.CoreIndex;
            r.efficiencyClass = info->CpuSet.EfficiencyClass;

            BYTE flags = info->CpuSet.AllFlags; // bit0=Parked, bit1=Allocated, bit2=AllocatedToTargetProcess, bit3=RealTime
            r.parked   = (flags & 0x01) ? 1 : 0;
            r.allocated= (flags & 0x02) ? 1 : 0;

            records[idx++] = r;

            if (r.efficiencyClass < minEff) minEff = r.efficiencyClass;
            if (r.efficiencyClass > maxEff) maxEff = r.efficiencyClass;
        }

        p += info->Size;
    }

    free(buffer);

    out->records = records;
    out->count   = count;
    out->minEff  = minEff;
    out->maxEff  = maxEff;

    // Build ID lists for "most efficient" (minEff) and "fastest" (maxEff)
    ULONG effCount = 0, fastCount = 0;
    for (size_t i = 0; i < out->count; i++) {
        if (out->records[i].efficiencyClass == out->minEff) effCount++;
        if (out->records[i].efficiencyClass == out->maxEff) fastCount++;
    }

    out->ids_most_efficient = (ULONG*)malloc(sizeof(ULONG) * (size_t)effCount);
    out->ids_fastest        = (ULONG*)malloc(sizeof(ULONG) * (size_t)fastCount);
    out->ids_most_efficient_count = effCount;
    out->ids_fastest_count        = fastCount;

    if ((!out->ids_most_efficient && effCount) || (!out->ids_fastest && fastCount)) {
        logf("[!] malloc for CpuSet ID lists failed.\n");
        free_snapshot(out);
        return false;
    }

    ULONG ei = 0, fi = 0;
    for (size_t i = 0; i < out->count; i++) {
        if (out->records[i].efficiencyClass == out->minEff) {
            out->ids_most_efficient[ei++] = out->records[i].id;
        }
        if (out->records[i].efficiencyClass == out->maxEff) {
            out->ids_fastest[fi++] = out->records[i].id;
        }
    }

    return true;
}

static const CpuSetRecord* find_record(const CpuSetSnapshot* snap, WORD group, BYTE lpIndex) {
    if (!snap) return NULL;
    for (size_t i = 0; i < snap->count; i++) {
        if (snap->records[i].group == group && snap->records[i].lpIndex == lpIndex) {
            return &snap->records[i];
        }
    }
    return NULL;
}

static const char* eff_label(const CpuSetSnapshot* snap, BYTE effClass) {
    if (!snap) return "unknown";
    if (snap->minEff == snap->maxEff) return "single-class (no hetero distinction)";
    if (effClass == snap->minEff) return "most-efficient class (likely E-cores)";
    if (effClass == snap->maxEff) return "fastest class (likely P-cores)";
    return "middle class";
}

static bool set_current_thread_ecoqos(bool enable) {
    THREAD_POWER_THROTTLING_STATE state;
    ZeroMemory(&state, sizeof(state));
    state.Version     = THREAD_POWER_THROTTLING_CURRENT_VERSION;
    state.ControlMask = THREAD_POWER_THROTTLING_EXECUTION_SPEED;
    state.StateMask   = enable ? THREAD_POWER_THROTTLING_EXECUTION_SPEED : 0;

    BOOL ok = SetThreadInformation(GetCurrentThread(),
                                   ThreadPowerThrottling,
                                   &state,
                                   (DWORD)sizeof(state));
    if (!ok) {
        print_last_error("SetThreadInformation(ThreadPowerThrottling)");
        return false;
    }
    return true;
}

static bool set_current_thread_cpu_sets(const ULONG* ids, ULONG count) {
    BOOL ok = SetThreadSelectedCpuSets(GetCurrentThread(), ids, count);
    if (!ok) {
        print_last_error("SetThreadSelectedCpuSets");
        return false;
    }
    return true;
}

typedef struct WorkerArgs {
    const char* name;
    const CpuSetSnapshot* snap;

    bool ecoqos;          // PowerThrottling hint
    int  threadPriority;  // e.g., THREAD_PRIORITY_BELOW_NORMAL

    const ULONG* cpuSetIds; // optional soft affinity
    ULONG cpuSetCount;

    int iterations;
    DWORD sleepMs;
} WorkerArgs;

static unsigned __stdcall worker_thread(void* param) {
    WorkerArgs* a = (WorkerArgs*)param;

    if (a->threadPriority != THREAD_PRIORITY_NORMAL) {
        SetThreadPriority(GetCurrentThread(), a->threadPriority);
    }

    if (a->ecoqos) {
        set_current_thread_ecoqos(true);
    }

    if (a->cpuSetIds && a->cpuSetCount > 0) {
        set_current_thread_cpu_sets(a->cpuSetIds, a->cpuSetCount);
    }

    for (int i = 0; i < a->iterations; i++) {
        PROCESSOR_NUMBER pn;
        GetCurrentProcessorNumberEx(&pn);

        const CpuSetRecord* r = find_record(a->snap, pn.Group, pn.Number);
        if (r) {
            logf("[%s] Running on G%u:CPU%u  CpuSetId=%lu  EffClass=%u (%s)%s\n",
                 a->name,
                 (unsigned)pn.Group,
                 (unsigned)pn.Number,
                 (unsigned long)r->id,
                 (unsigned)r->efficiencyClass,
                 eff_label(a->snap, r->efficiencyClass),
                 r->parked ? "  [PARKED?]" : "");
        } else {
            logf("[%s] Running on G%u:CPU%u  (no matching CpuSet record)\n",
                 a->name,
                 (unsigned)pn.Group,
                 (unsigned)pn.Number);
        }

        Sleep(a->sleepMs);
    }

    return 0;
}

static void print_cpu_sets(const CpuSetSnapshot* s) {
    logf("=== CPU Sets (%zu entries) ===\n", s->count);
    logf("EfficiencyClass: min=%u (most efficient), max=%u (fastest)\n",
         (unsigned)s->minEff, (unsigned)s->maxEff);

    for (size_t i = 0; i < s->count; i++) {
        const CpuSetRecord* r = &s->records[i];
        logf("  Id=%lu  Group=%u  LPIndex=%u  CoreIndex=%u  EffClass=%u  Parked=%u  Allocated=%u\n",
             (unsigned long)r->id,
             (unsigned)r->group,
             (unsigned)r->lpIndex,
             (unsigned)r->coreIndex,
             (unsigned)r->efficiencyClass,
             (unsigned)r->parked,
             (unsigned)r->allocated);
    }

    logf("Most-efficient CpuSetIds count=%lu, Fastest CpuSetIds count=%lu\n\n",
         (unsigned long)s->ids_most_efficient_count,
         (unsigned long)s->ids_fastest_count);
}

int main(void) {
    InitializeCriticalSection(&g_logLock);

    CpuSetSnapshot snap;
    if (!build_cpu_set_snapshot(&snap)) {
        logf("[!] Failed to build CPU set snapshot.\n");
        DeleteCriticalSection(&g_logLock);
        return 1;
    }

    print_cpu_sets(&snap);

    // Worker configurations:
    WorkerArgs normal = {
        "NORMAL",
        &snap,
        false,                      // ecoqos
        THREAD_PRIORITY_NORMAL,
        NULL, 0,                    // no CPU sets
        20, 250
    };

    WorkerArgs ecoqos_only = {
        "ECOQOS_ONLY",
        &snap,
        true,                       // ecoqos hint
        THREAD_PRIORITY_BELOW_NORMAL,
        NULL, 0,                    // no CPU sets; let scheduler decide with hint
        20, 250
    };

    WorkerArgs most_efficient_sets = {
        "CPUSET_E_CLASS",
        &snap,
        true,                       // you can set this false if you want to test CPU sets alone
        THREAD_PRIORITY_BELOW_NORMAL,
        snap.ids_most_efficient,
        snap.ids_most_efficient_count,
        20, 250
    };

    WorkerArgs fastest_sets = {
        "CPUSET_P_CLASS",
        &snap,
        false,                      // keep normal QoS, but restrict to fastest sets
        THREAD_PRIORITY_NORMAL,
        snap.ids_fastest,
        snap.ids_fastest_count,
        20, 250
    };

    HANDLE threads[4] = {0};
    unsigned tid = 0;

    threads[0] = (HANDLE)_beginthreadex(NULL, 0, worker_thread, &normal, 0, &tid);
    threads[1] = (HANDLE)_beginthreadex(NULL, 0, worker_thread, &ecoqos_only, 0, &tid);
    threads[2] = (HANDLE)_beginthreadex(NULL, 0, worker_thread, &most_efficient_sets, 0, &tid);
    threads[3] = (HANDLE)_beginthreadex(NULL, 0, worker_thread, &fastest_sets, 0, &tid);

    for (int i = 0; i < 4; i++) {
        if (!threads[i]) {
            logf("[!] _beginthreadex failed for thread %d.\n", i);
        }
    }

    WaitForMultipleObjects(4, threads, TRUE, INFINITE);
    for (int i = 0; i < 4; i++) {
        if (threads[i]) CloseHandle(threads[i]);
    }

    free_snapshot(&snap);
    DeleteCriticalSection(&g_logLock);
    return 0;
}
