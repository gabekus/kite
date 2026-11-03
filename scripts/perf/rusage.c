// Samples one process's resource usage (proc_pid_rusage, no root needed) over an interval and prints
// per-second rates: CPU ms, idle wakeups, interrupt wakeups, energy (nJ), and the footprint at the end.
// Build: cc -O2 -o build/perf/rusage scripts/perf/rusage.c
// Usage: rusage PID SECONDS
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: rusage PID SECONDS\n"); return 2; }
    int pid = atoi(argv[1]), secs = atoi(argv[2]);
    struct rusage_info_v4 a, b;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&a)) { perror("proc_pid_rusage"); return 1; }
    sleep(secs);
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&b)) { perror("proc_pid_rusage"); return 1; }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double cpu_ns = (double)((b.ri_user_time + b.ri_system_time) - (a.ri_user_time + a.ri_system_time)) * tb.numer / tb.denom;
    printf("cpu_ms_per_s=%.2f idle_wakeups_per_s=%.2f interrupt_wakeups_per_s=%.2f billed_energy_nj_per_s=%.0f footprint_mb=%.1f\n",
           cpu_ns / 1e6 / secs,
           (double)(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups) / secs,
           (double)(b.ri_interrupt_wkups - a.ri_interrupt_wkups) / secs,
           (double)(b.ri_billed_energy - a.ri_billed_energy) / secs,
           b.ri_phys_footprint / 1048576.0);
    return 0;
}
