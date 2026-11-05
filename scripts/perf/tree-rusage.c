// Samples several processes' resource usage (proc_pid_rusage, no root needed) over one interval and prints
// per-process and total rates: CPU ms, idle and interrupt wakeups, billed energy and the kernel's energy
// estimate (µJ, ri_energy_nj), and the footprint at the end. For Kite's main process plus its Chromium
// helpers (renderers, GPU, network).
// A process that exits mid-interval is left out of the totals; one that starts mid-interval isn't sampled.
// Build: cc -O2 -o build/perf/tree-rusage scripts/perf/tree-rusage.c
// Usage: tree-rusage SECONDS PID...
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAXPROCS 256

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: tree-rusage SECONDS PID...\n"); return 2; }
    int secs = atoi(argv[1]), n = argc - 2;
    if (n > MAXPROCS) n = MAXPROCS;
    int pids[MAXPROCS], ok[MAXPROCS];
    struct rusage_info_v6 a[MAXPROCS], b[MAXPROCS];
    for (int i = 0; i < n; i++) {
        pids[i] = atoi(argv[i + 2]);
        ok[i] = proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&a[i]) == 0;
    }
    sleep(secs);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double t_cpu = 0, t_idle = 0, t_intr = 0, t_energy = 0, t_nj = 0, t_mb = 0;
    int counted = 0;
    for (int i = 0; i < n; i++) {
        if (!ok[i] || proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&b[i])) continue;
        char name[64] = {0};
        proc_name(pids[i], name, sizeof name);
        double cpu = (double)((b[i].ri_user_time + b[i].ri_system_time) - (a[i].ri_user_time + a[i].ri_system_time))
                     * tb.numer / tb.denom / 1e6 / secs;
        double idle = (double)(b[i].ri_pkg_idle_wkups - a[i].ri_pkg_idle_wkups) / secs;
        double intr = (double)(b[i].ri_interrupt_wkups - a[i].ri_interrupt_wkups) / secs;
        double energy = (double)(b[i].ri_billed_energy - a[i].ri_billed_energy) / 1e3 / secs;
        double nj = (double)(b[i].ri_energy_nj - a[i].ri_energy_nj) / 1e3 / secs;
        double mb = b[i].ri_phys_footprint / 1048576.0;
        printf("  %-28s pid=%-6d cpu_ms_per_s=%7.2f idle_wk=%6.2f intr_wk=%6.2f billed_uj_per_s=%8.0f energy_uj_per_s=%8.0f footprint_mb=%7.1f\n",
               name, pids[i], cpu, idle, intr, energy, nj, mb);
        t_cpu += cpu; t_idle += idle; t_intr += intr; t_energy += energy; t_nj += nj; t_mb += mb; counted++;
    }
    printf("TOTAL procs=%d cpu_ms_per_s=%.2f idle_wakeups_per_s=%.2f interrupt_wakeups_per_s=%.2f billed_uj_per_s=%.0f energy_uj_per_s=%.0f footprint_mb=%.1f\n",
           counted, t_cpu, t_idle, t_intr, t_energy, t_nj, t_mb);
    return 0;
}
