#include <stdint.h>
#include "printf.h"
#include "runtime.h"
#include "synchronization.h"

int main() {
  uint32_t cid = mempool_get_core_id();
  uint32_t nc = mempool_get_core_count();
  if (cid == 0) printf("P0 pre-barrier\n");
  mempool_barrier_init(cid);
  if (cid == 0) printf("P0b barrier-init done\n");
  mempool_barrier(nc);
  if (cid == 0) printf("P1 first barrier OK\n");
  for (int i = 0; i < 20; i++) mempool_barrier(nc);
  if (cid == 0) printf("P2 twenty barriers OK\n");
  return 0;
}
