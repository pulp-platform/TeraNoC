// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: Apache-2.0
//
// Give this translation unit its own copies of the globally visible functions it pulls in
// through headers, so several phases (each its own TU with its own shape macros) link together.
// Include BEFORE kernel/qwen-fmatmul.c and runtime/dma.h, with QP_PFX(x) defined (e.g. gu_##x).
//   * kernel/qwen-fmatmul.c: matmul_{1,2,4,8}xVL are global (KERNEL_ATTR, not static)
//   * runtime/dma.h: dma_memcpy_nonblocking / dma_memcpy_blocking are defined without `static`
#ifndef QWEN_TU_PREFIX_H
#define QWEN_TU_PREFIX_H
#ifndef QP_PFX
#error "qwen_tu_prefix.h needs QP_PFX(x)"
#endif
#define matmul_1xVL QP_PFX(matmul_1xVL)
#define matmul_2xVL QP_PFX(matmul_2xVL)
#define matmul_4xVL QP_PFX(matmul_4xVL)
#define matmul_8xVL QP_PFX(matmul_8xVL)
#define dma_memcpy_nonblocking QP_PFX(dma_memcpy_nonblocking)
#define dma_memcpy_blocking QP_PFX(dma_memcpy_blocking)
#endif
