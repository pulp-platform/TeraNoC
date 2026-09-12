// Optional application helper. Include and call outside the timed region.
#ifndef SIM_DASHBOARD_WORKLOAD_H
#define SIM_DASHBOARD_WORKLOAD_H
#include <stdint.h>
#include <stdio.h>

// Call once on hart 0 after selecting the kernel, outside the timed region.
static inline void dashboard_kernel_size(uint32_t kernel_size) {
  printf("[DASHBOARD_META] {\"kernel_size\":%u}\n", (unsigned)kernel_size);
}

// Call once on hart 0 with the actual group assignment, including repetitions.
// All inputs are numeric; precision must be the literal "fp16" or "fp32".
static inline void dashboard_workload(uint32_t m, uint32_t n, uint32_t p,
                                     const char *precision, uint32_t repeats,
                                     uint32_t groups, const uint64_t *work) {
  printf("[DASHBOARD_META] {\"shape\":[%u,%u,%u],\"precision\":\"%s\","
         "\"repetitions\":%u,\"expected_fmac_per_group\":[",
         m, n, p, precision, repeats);
  for (uint32_t g = 0; g < groups; ++g) {
    printf("%s%llu", g ? "," : "", (unsigned long long)work[g]);
  }
  printf("]}\n");
}
#endif
