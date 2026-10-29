// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// RTL stand-in for the post-layout netlist of mempool_group_floonoc_wrapper.
//
// It carries the netlist's module name and the port list a synthesised top exposes: every struct
// port flattened to a plain logic vector, and dma_meta_o split into one bit per field. Inside it
// is just the RTL group. Compiling it in place of the netlist validates the whole post-layout
// harness -- TB elaboration with group (0,0) swapped out, the port-width checks, the initreg
// scoping -- and must reproduce the plain RTL run cycle for cycle.
//
// Never compile it together with a real netlist: both define the same module.
//
// +define+POSTLAYOUT_STANDIN_BREAK_WIDTH narrows floo_tcdm_rsp_o by one bit, to prove that the
// width checks in terapool_cluster_floonoc_wrapper reject a netlist that does not match the RTL.

`include "mempool/mempool.svh"

module mempool_group_floonoc_wrapper_postlayout
  import mempool_pkg::*;
  import floo_pkg::*;
  import floo_terapool_noc_pkg::*;
(
  input  logic                                       clk_i,
  input  logic                                       rst_ni,
  input  logic                                       testmode_i,
  input  logic                                       scan_enable_i,
  input  logic                                       scan_data_i,
  output logic                                       scan_data_o,
  input  logic [$bits(group_id_t)-1:0]               group_id_i,
  input  logic [$bits(id_t)-1:0]                     floo_id_i,
  output logic [4*$bits(floo_tcdm_req_if_t)-1:0]     floo_tcdm_req_o,
`ifdef POSTLAYOUT_STANDIN_BREAK_WIDTH
  output logic [4*$bits(floo_tcdm_rsp_if_t)-2:0]     floo_tcdm_rsp_o,
`else
  output logic [4*$bits(floo_tcdm_rsp_if_t)-1:0]     floo_tcdm_rsp_o,
`endif
  input  logic [4*$bits(floo_tcdm_req_if_t)-1:0]     floo_tcdm_req_i,
  input  logic [4*$bits(floo_tcdm_rsp_if_t)-1:0]     floo_tcdm_rsp_i,
  input  logic [NumCoresPerGroup-1:0]                wake_up_i,
  input  logic [$bits(ro_cache_ctrl_t)-1:0]          ro_cache_ctrl_i,
  input  logic [$bits(dma_req_t)-1:0]                dma_req_i,
  input  logic                                       dma_req_valid_i,
  output logic                                       dma_req_ready_o,
  output logic                                       dma_meta_o_backend_idle_,
  output logic                                       dma_meta_o_trans_complete_,
  output logic [4*$bits(floo_req_t)-1:0]             floo_axi_req_o,
  output logic [4*$bits(floo_rsp_t)-1:0]             floo_axi_rsp_o,
  output logic [4*$bits(floo_wide_t)-1:0]            floo_axi_wide_o,
  input  logic [4*$bits(floo_req_t)-1:0]             floo_axi_req_i,
  input  logic [4*$bits(floo_rsp_t)-1:0]             floo_axi_rsp_i,
  input  logic [4*$bits(floo_wide_t)-1:0]            floo_axi_wide_i
);

  dma_meta_t dma_meta;
  assign dma_meta_o_backend_idle_   = dma_meta.backend_idle;
  assign dma_meta_o_trans_complete_ = dma_meta.trans_complete;

  mempool_group_floonoc_wrapper #(
    .TCDMBaseAddr (32'h0     ),
    .BootAddr     (`BOOT_ADDR)
  ) i_group (
    .clk_i           (clk_i          ),
    .rst_ni          (rst_ni         ),
    .testmode_i      (testmode_i     ),
    .scan_enable_i   (scan_enable_i  ),
    .scan_data_i     (scan_data_i    ),
    .scan_data_o     (scan_data_o    ),
    .group_id_i      (group_id_i     ),
    .floo_id_i       (floo_id_i      ),
    .floo_tcdm_req_o (floo_tcdm_req_o),
    .floo_tcdm_rsp_o (floo_tcdm_rsp_o),
    .floo_tcdm_req_i (floo_tcdm_req_i),
    .floo_tcdm_rsp_i (floo_tcdm_rsp_i),
    .floo_axi_req_o  (floo_axi_req_o ),
    .floo_axi_rsp_o  (floo_axi_rsp_o ),
    .floo_axi_wide_o (floo_axi_wide_o),
    .floo_axi_req_i  (floo_axi_req_i ),
    .floo_axi_rsp_i  (floo_axi_rsp_i ),
    .floo_axi_wide_i (floo_axi_wide_i),
    .wake_up_i       (wake_up_i      ),
    .ro_cache_ctrl_i (ro_cache_ctrl_i),
    .dma_req_i       (dma_req_i      ),
    .dma_req_valid_i (dma_req_valid_i),
    .dma_req_ready_o (dma_req_ready_o),
    .dma_meta_o      (dma_meta       )
  );

endmodule
