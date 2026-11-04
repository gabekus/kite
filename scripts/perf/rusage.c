// Samples resource usage (proc_pid_rusage, no root needed) over an interval and prints per-second rates:
// CPU ms, idle wakeups, interrupt wakeups, energy (nJ), bytes written to disk, and the footprint at the end.
// With more PIDs it prints their sum (a process that exits during the interval counts for none of it).
// Build: cc -O2 -o build/perf/rusage scripts/perf/rusage.c
// Usage: rusage PID SECONDS [PID...]
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: rusage PID SECONDS [PID...]\n"); return 2; }
    int secs = atoi(argv[2]);
    int n = argc - 2;
    int *pids = calloc(n, sizeof(int));
    pids[0] = atoi(argv[1]);
    for (int i = 3; i < argc; i++) pids[i - 2] = atoi(argv[i]);
    struct rusage_info_v4 *a = calloc(n, sizeof(*a)), *b = calloc(n, sizeof(*b));
    int *ok = calloc(n, sizeof(int));
    for (int i = 0; i < n; i++) ok[i] = proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&a[i]) == 0;
    if (!ok[0]) { perror("proc_pid_rusage"); return 1; }
    sleep(secs);
    for (int i = 0; i < n; i++) ok[i] = ok[i] && proc_pid_rusage(pids[i], RUSAGE_INFO_V4, (rusage_info_t *)&b[i]) == 0;
    if (!ok[0]) { perror("proc_pid_rusage"); return 1; }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double cpu_ns = 0, idle = 0, interrupts = 0, energy = 0, written = 0, footprint = 0;
    for (int i = 0; i < n; i++) {
        if (!ok[i]) continue;
        cpu_ns += (double)((b[i].ri_user_time + b[i].ri_system_time) - (a[i].ri_user_time + a[i].ri_system_time)) * tb.numer / tb.denom;
        idle += (double)(b[i].ri_pkg_idle_wkups - a[i].ri_pkg_idle_wkups);
        interrupts += (double)(b[i].ri_interrupt_wkups - a[i].ri_interrupt_wkups);
        energy += (double)(b[i].ri_billed_energy - a[i].ri_billed_energy);
        written += (double)(b[i].ri_diskio_byteswritten - a[i].ri_diskio_byteswritten);
        footprint += b[i].ri_phys_footprint;
    }
    printf("cpu_ms_per_s=%.2f idle_wakeups_per_s=%.2f interrupt_wakeups_per_s=%.2f billed_energy_nj_per_s=%.0f "
           "disk_written_bytes_per_s=%.0f footprint_mb=%.1f\n",
           cpu_ns / 1e6 / secs, idle / secs, interrupts / secs, energy / secs, written / secs, footprint / 1048576.0);
    return 0;
}
