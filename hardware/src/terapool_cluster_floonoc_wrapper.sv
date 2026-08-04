// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Yichao Zhang <yiczhang@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module terapool_cluster_floonoc_wrapper
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
  import floo_pkg::*;
  import floo_terapool_noc_pkg::*;
#(
  // TCDM
  parameter addr_t        TCDMBaseAddr   = 32'b0,
  // Boot address
  parameter logic [31:0]  BootAddr       = 32'h0000_0000,
  // Dependant parameters. DO NOT CHANGE!
  parameter int unsigned  NumDMAReq      = NumGroups * NumDmasPerGroup,
  parameter int unsigned  NumAXIMasters  = NumL2Channels
) (
  // Clock and reset
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          testmode_i,

  // Scan chain
  input  logic                          scan_enable_i,
  input  logic                          scan_data_i,
  output logic                          scan_data_o,

  // Wake-up signal
  input  logic         [NumCores-1:0]   wake_up_i,

  // RO-Cache configuration
  input  ro_cache_ctrl_t                ro_cache_ctrl_i,

  // DMA request
  input  dma_req_t     [NumGroups-1:0]  dma_req_i,
  input  logic         [NumGroups-1:0]  dma_req_valid_i,
  output logic         [NumGroups-1:0]  dma_req_ready_o,

  // DMA status
  output dma_meta_t    [NumGroups-1:0]  dma_meta_o,

  // AXI Interface
  input  floo_req_t    [NumAXIMasters-1:0] floo_axi_req_i,
  input  floo_rsp_t    [NumAXIMasters-1:0] floo_axi_rsp_i,
  input  floo_wide_t   [NumAXIMasters-1:0] floo_axi_wide_i,
  output floo_req_t    [NumAXIMasters-1:0] floo_axi_req_o,
  output floo_rsp_t    [NumAXIMasters-1:0] floo_axi_rsp_o,
  output floo_wide_t   [NumAXIMasters-1:0] floo_axi_wide_o
);

  /*********************
   *  Control Signals  *
   *********************/
  logic [NumCores-1:0] wake_up_q;
  `FF(wake_up_q, wake_up_i, '0, clk_i, rst_ni);

  ro_cache_ctrl_t [NumGroups-1:0] ro_cache_ctrl_q;
  for (genvar g = 0; unsigned'(g) < NumGroups; g++) begin : gen_ro_cache_ctrl_q
    `FF(ro_cache_ctrl_q[g], ro_cache_ctrl_i, ro_cache_ctrl_default, clk_i, rst_ni);
  end : gen_ro_cache_ctrl_q

  /*********
   *  DMA  *
   *********/
  dma_req_t  [NumGroups-1:0] dma_req_group, dma_req_group_q;
  logic      [NumGroups-1:0] dma_req_group_valid, dma_req_group_q_valid;
  logic      [NumGroups-1:0] dma_req_group_ready, dma_req_group_q_ready;
  dma_meta_t [NumGroups-1:0] dma_meta, dma_meta_q;

  assign dma_req_group = dma_req_i;
  assign dma_req_group_valid = dma_req_valid_i;
  assign dma_req_ready_o = dma_req_group_ready;
  assign dma_meta_o = dma_meta_q;

  `FF(dma_meta_q, dma_meta, '0, clk_i, rst_ni);

  for (genvar g = 0; unsigned'(g) < NumGroups; g++) begin: gen_dma_req_group_register
    spill_register #(
      .T(dma_req_t)
    ) i_dma_req_group_register (
      .clk_i  (clk_i                   ),
      .rst_ni (rst_ni                  ),
      .data_i (dma_req_group[g]        ),
      .valid_i(dma_req_group_valid[g]  ),
      .ready_o(dma_req_group_ready[g]  ),
      .data_o (dma_req_group_q[g]      ),
      .valid_o(dma_req_group_q_valid[g]),
      .ready_i(dma_req_group_q_ready[g])
    );
  end : gen_dma_req_group_register

  /************
   *  Groups  *
   ************/
  // FlooNoC TCDM interfaces
  floo_tcdm_req_if_t [NumX-1:0][NumY-1:0][West:North] floo_tcdm_req_out, floo_tcdm_req_in;
  floo_tcdm_rsp_if_t [NumX-1:0][NumY-1:0][West:North] floo_tcdm_rsp_out, floo_tcdm_rsp_in;

  // FlooNoC AXI interfaces
  floo_terapool_noc_pkg::floo_req_t  [NumX-1:0][NumY-1:0][West:North] floo_axi_req_out,  floo_axi_req_in;
  floo_terapool_noc_pkg::floo_rsp_t  [NumX-1:0][NumY-1:0][West:North] floo_axi_rsp_out,  floo_axi_rsp_in;
  floo_terapool_noc_pkg::floo_wide_t [NumX-1:0][NumY-1:0][West:North] floo_axi_wide_out, floo_axi_wide_in;

  // Chimney configuration
  localparam floo_pkg::chimney_cfg_t ChimneyCfgN = floo_pkg::set_ports(floo_pkg::ChimneyDefaultCfg, 1'b0, 1'b0);
  localparam floo_pkg::chimney_cfg_t ChimneyCfgW = floo_pkg::set_ports(floo_pkg::ChimneyDefaultCfg, 1'b1, 1'b0);

  for (genvar x = 0; x < NumX; x++) begin : gen_groups_x
    for (genvar y = 0; y < NumY; y++) begin : gen_groups_y
      group_xy_id_t group_id;
      assign group_id = '{x:x, y:y, port_id:1'b0};

      if (x == 0) begin : gen_hbm_chimney_west
        // West
        if (NocTopology == 1) begin
          assign floo_tcdm_req_in[x][y][West] = floo_tcdm_req_out[NumX-1][y][East];
          assign floo_tcdm_rsp_in[x][y][West] = floo_tcdm_rsp_out[NumX-1][y][East];
        end else begin
          assign floo_tcdm_req_in[x][y][West] = '0;
          assign floo_tcdm_rsp_in[x][y][West] = '0;
        end

        // East
        assign floo_tcdm_req_in[x][y][East] = floo_tcdm_req_out[x+1][y][West];
        assign floo_tcdm_rsp_in[x][y][East] = floo_tcdm_rsp_out[x+1][y][West];

        // AXI East
        assign floo_axi_req_in[x][y][East]  = floo_axi_req_out[x+1][y][West];
        assign floo_axi_rsp_in[x][y][East]  = floo_axi_rsp_out[x+1][y][West];
        assign floo_axi_wide_in[x][y][East] = floo_axi_wide_out[x+1][y][West];
        // AXI West
        localparam int unsigned WestCh = perimeter_map_pkg::PerimeterChannel[x][y][West];
        assign floo_axi_req_in[x][y][West]  = floo_axi_req_i[WestCh];
        assign floo_axi_rsp_in[x][y][West]  = floo_axi_rsp_i[WestCh];
        assign floo_axi_wide_in[x][y][West] = floo_axi_wide_i[WestCh];
        assign floo_axi_wide_o[WestCh]      = floo_axi_wide_out[x][y][West];
        assign floo_axi_req_o[WestCh]       = floo_axi_req_out[x][y][West];
        assign floo_axi_rsp_o[WestCh]       = floo_axi_rsp_out[x][y][West];

      end else if (x == NumX-1) begin : gen_hbm_chimney_east
        // East
        if (NocTopology == 1) begin
          assign floo_tcdm_req_in[x][y][East] = floo_tcdm_req_out[0][y][West];
          assign floo_tcdm_rsp_in[x][y][East] = floo_tcdm_rsp_out[0][y][West];
        end else begin
          assign floo_tcdm_req_in[x][y][East] = '0;
          assign floo_tcdm_rsp_in[x][y][East] = '0;
        end

        // West
        assign floo_tcdm_req_in[x][y][West] = floo_tcdm_req_out[x-1][y][East];
        assign floo_tcdm_rsp_in[x][y][West] = floo_tcdm_rsp_out[x-1][y][East];

        // AXI West
        assign floo_axi_req_in[x][y][West]  = floo_axi_req_out[x-1][y][East];
        assign floo_axi_rsp_in[x][y][West]  = floo_axi_rsp_out[x-1][y][East];
        assign floo_axi_wide_in[x][y][West] = floo_axi_wide_out[x-1][y][East];

        // AXI East
        localparam int unsigned EastCh = perimeter_map_pkg::PerimeterChannel[x][y][East];
        assign floo_axi_req_in[x][y][East]  = floo_axi_req_i[EastCh];
        assign floo_axi_rsp_in[x][y][East]  = floo_axi_rsp_i[EastCh];
        assign floo_axi_wide_in[x][y][East] = floo_axi_wide_i[EastCh];
        assign floo_axi_wide_o[EastCh]      = floo_axi_wide_out[x][y][East];
        assign floo_axi_req_o[EastCh]       = floo_axi_req_out[x][y][East];
        assign floo_axi_rsp_o[EastCh]       = floo_axi_rsp_out[x][y][East];

      end else begin : gen_hor_connections
        // East
        assign floo_tcdm_req_in[x][y][East] = floo_tcdm_req_out[x+1][y][West];
        assign floo_tcdm_rsp_in[x][y][East] = floo_tcdm_rsp_out[x+1][y][West];
        assign floo_axi_req_in[x][y][East]  = floo_axi_req_out[x+1][y][West];
        assign floo_axi_rsp_in[x][y][East]  = floo_axi_rsp_out[x+1][y][West];
        assign floo_axi_wide_in[x][y][East] = floo_axi_wide_out[x+1][y][West];

        // West
        assign floo_tcdm_req_in[x][y][West] = floo_tcdm_req_out[x-1][y][East];
        assign floo_tcdm_rsp_in[x][y][West] = floo_tcdm_rsp_out[x-1][y][East];
        assign floo_axi_req_in[x][y][West]  = floo_axi_req_out[x-1][y][East];
        assign floo_axi_rsp_in[x][y][West]  = floo_axi_rsp_out[x-1][y][East];
        assign floo_axi_wide_in[x][y][West] = floo_axi_wide_out[x-1][y][East];
      end

      if (y == 0) begin : gen_hbm_chimney_south
        // South
        if (NocTopology == 1) begin
          assign floo_tcdm_req_in[x][y][South] = floo_tcdm_req_out[x][NumY-1][North];
          assign floo_tcdm_rsp_in[x][y][South] = floo_tcdm_rsp_out[x][NumY-1][North];
        end else begin
          assign floo_tcdm_req_in[x][y][South] = '0;
          assign floo_tcdm_rsp_in[x][y][South] = '0;
        end

        // North
        assign floo_tcdm_req_in [x][y][North] = floo_tcdm_req_out [x][y+1][South];
        assign floo_tcdm_rsp_in [x][y][North] = floo_tcdm_rsp_out [x][y+1][South];

        // AXI North
        assign floo_axi_req_in  [x][y][North] = floo_axi_req_out  [x][y+1][South];
        assign floo_axi_rsp_in  [x][y][North] = floo_axi_rsp_out  [x][y+1][South];
        assign floo_axi_wide_in [x][y][North] = floo_axi_wide_out [x][y+1][South];

        // The three-way split that used to live here existed only to compute the
        // channel index ([5-x], [x+6], [5]); the generated map supplies it.
        localparam int unsigned SouthCh = perimeter_map_pkg::PerimeterChannel[x][y][South];
        assign floo_axi_req_in[x][y][South]  = floo_axi_req_i[SouthCh];
        assign floo_axi_rsp_in[x][y][South]  = floo_axi_rsp_i[SouthCh];
        assign floo_axi_wide_in[x][y][South] = floo_axi_wide_i[SouthCh];
        assign floo_axi_wide_o[SouthCh]      = floo_axi_wide_out[x][y][South];
        assign floo_axi_req_o[SouthCh]       = floo_axi_req_out[x][y][South];
        assign floo_axi_rsp_o[SouthCh]       = floo_axi_rsp_out[x][y][South];

      end else if (y == NumY-1) begin
        // TCDM North
        if (NocTopology == 1) begin
          assign floo_tcdm_req_in[x][y][North] = floo_tcdm_req_out[x][0][South];
          assign floo_tcdm_rsp_in[x][y][North] = floo_tcdm_rsp_out[x][0][South];
        end else begin
          assign floo_tcdm_req_in[x][y][North] = '0;
          assign floo_tcdm_rsp_in[x][y][North] = '0;
        end

        // TCDM South
        assign floo_tcdm_req_in[x][y][South] = floo_tcdm_req_out[x][y-1][North];
        assign floo_tcdm_rsp_in[x][y][South] = floo_tcdm_rsp_out[x][y-1][North];

        // AXI South
        assign floo_axi_req_in [x][y][South] = floo_axi_req_out [x][y-1][North];
        assign floo_axi_rsp_in [x][y][South] = floo_axi_rsp_out [x][y-1][North];
        assign floo_axi_wide_in[x][y][South] = floo_axi_wide_out[x][y-1][North];

        // The x < NumX/2 split that used to live here existed only to compute the
        // channel index ([x+6], [13-x]); the generated map supplies it.
        localparam int unsigned NorthCh = perimeter_map_pkg::PerimeterChannel[x][y][North];
        assign floo_axi_req_in [x][y][North] = floo_axi_req_i [NorthCh];
        assign floo_axi_rsp_in [x][y][North] = floo_axi_rsp_i [NorthCh];
        assign floo_axi_wide_in[x][y][North] = floo_axi_wide_i[NorthCh];
        assign floo_axi_wide_o [NorthCh]     = floo_axi_wide_out[x][y][North];
        assign floo_axi_req_o  [NorthCh]     = floo_axi_req_out [x][y][North];
        assign floo_axi_rsp_o  [NorthCh]     = floo_axi_rsp_out [x][y][North];

      end else begin
        // North
        assign floo_tcdm_req_in [x][y][North] = floo_tcdm_req_out [x][y+1][South];
        assign floo_tcdm_rsp_in [x][y][North] = floo_tcdm_rsp_out [x][y+1][South];
        assign floo_axi_req_in  [x][y][North] = floo_axi_req_out  [x][y+1][South];
        assign floo_axi_rsp_in  [x][y][North] = floo_axi_rsp_out  [x][y+1][South];
        assign floo_axi_wide_in [x][y][North] = floo_axi_wide_out [x][y+1][South];

        // South
        assign floo_tcdm_req_in [x][y][South] = floo_tcdm_req_out [x][y-1][North];
        assign floo_tcdm_rsp_in [x][y][South] = floo_tcdm_rsp_out [x][y-1][North];
        assign floo_axi_req_in  [x][y][South] = floo_axi_req_out  [x][y-1][North];
        assign floo_axi_rsp_in  [x][y][South] = floo_axi_rsp_out  [x][y-1][North];
        assign floo_axi_wide_in [x][y][South] = floo_axi_wide_out [x][y-1][North];
      end

      if (PostLayoutGr & (x == 0) & (y == 0)) begin : gen_postly_group
        mempool_group_floonoc_wrapper_postlayout i_group (
          .clk_i              (clk_i),
          .rst_ni             (rst_ni),
          .testmode_i         (testmode_i),
          .scan_enable_i      (scan_enable_i),
          .scan_data_i        (/* Unconnected */),
          .scan_data_o        (/* Unconnected */),
          .group_id_i         (group_id_t'({group_id.x, group_id.y})),
          .floo_id_i          (id_t'(GroupX0Y0 + x*NumY + y)),
          // TCDM Router interface
          .floo_tcdm_req_o    (floo_tcdm_req_out[x][y]),
          .floo_tcdm_rsp_o    (floo_tcdm_rsp_out[x][y]),
          .floo_tcdm_req_i    (floo_tcdm_req_in[x][y]),
          .floo_tcdm_rsp_i    (floo_tcdm_rsp_in[x][y]),
          .wake_up_i          (wake_up_q[(NumY*x+y)*NumCoresPerGroup +: NumCoresPerGroup]),
          .ro_cache_ctrl_i    (ro_cache_ctrl_q[(NumY*x+y)]),
          // DMA request
          .dma_req_i          (dma_req_group_q[(NumY*x+y)]),
          .dma_req_valid_i    (dma_req_group_q_valid[(NumY*x+y)]),
          .dma_req_ready_o    (dma_req_group_q_ready[(NumY*x+y)]),
          // DMA status
          .dma_meta_o_backend_idle_   (dma_meta[(NumY*x+y)][1]),
          .dma_meta_o_trans_complete_ (dma_meta[(NumY*x+y)][0]),
          // AXI Router interface
          .floo_axi_req_o     (floo_axi_req_out[x][y]),
          .floo_axi_rsp_o     (floo_axi_rsp_out[x][y]),
          .floo_axi_wide_o    (floo_axi_wide_out[x][y]),
          .floo_axi_req_i     (floo_axi_req_in[x][y]),
          .floo_axi_rsp_i     (floo_axi_rsp_in[x][y]),
          .floo_axi_wide_i    (floo_axi_wide_in[x][y])
        );

      end else begin : gen_rtl_group
        mempool_group_floonoc_wrapper #(
          .TCDMBaseAddr       (TCDMBaseAddr),
          .BootAddr           (BootAddr)
        ) i_group (
          .clk_i              (clk_i),
          .rst_ni             (rst_ni),
          .testmode_i         (testmode_i),
          .scan_enable_i      (scan_enable_i),
          .scan_data_i        (/* Unconnected */),
          .scan_data_o        (/* Unconnected */),
          .group_id_i         (group_id_t'({group_id.x, group_id.y})),
          .floo_id_i          (id_t'(GroupX0Y0 + x*NumY + y)),
          // TCDM Router interface
          .floo_tcdm_req_o    (floo_tcdm_req_out[x][y]),
          .floo_tcdm_rsp_o    (floo_tcdm_rsp_out[x][y]),
          .floo_tcdm_req_i    (floo_tcdm_req_in[x][y]),
          .floo_tcdm_rsp_i    (floo_tcdm_rsp_in[x][y]),
          .wake_up_i          (wake_up_q[(NumY*x+y)*NumCoresPerGroup +: NumCoresPerGroup]),
          .ro_cache_ctrl_i    (ro_cache_ctrl_q[(NumY*x+y)]),
          // DMA request
          .dma_req_i          (dma_req_group_q[(NumY*x+y)]),
          .dma_req_valid_i    (dma_req_group_q_valid[(NumY*x+y)]),
          .dma_req_ready_o    (dma_req_group_q_ready[(NumY*x+y)]),
          // DMA status
          .dma_meta_o         (dma_meta[(NumY*x+y)]),
          // AXI Router interface
          .floo_axi_req_o     (floo_axi_req_out[x][y]),
          .floo_axi_rsp_o     (floo_axi_rsp_out[x][y]),
          .floo_axi_wide_o    (floo_axi_wide_out[x][y]),
          .floo_axi_req_i     (floo_axi_req_in[x][y]),
          .floo_axi_rsp_i     (floo_axi_rsp_in[x][y]),
          .floo_axi_wide_i    (floo_axi_wide_in[x][y])
        );
      end
    end : gen_groups_y
  end : gen_groups_x

  /****************
   *  Assertions  *
   ****************/

  if (NumCores > 1024)
    $fatal(1, "[mempool] MemPool is currently limited to 1024 cores.");

  if (NumTiles < NumGroups)
    $fatal(1, "[mempool] MemPool requires more tiles than groups.");

  if (NumCores != NumTiles * NumCoresPerTile)
    $fatal(1, "[mempool] The number of cores is not divisible by the number of cores per tile.");

  if (BankingFactor < 1)
    $fatal(1, "[mempool] The banking factor must be a positive integer.");

  if (BankingFactor != 2**$clog2(BankingFactor))
    $fatal(1, "[mempool] The banking factor must be a power of two.");

  /**********************************
   *  Mesh / group-id elaboration   *
   **********************************/
  // The mesh coordinate is not computed anywhere -- it is BIT-CAST out of the flat
  // group id, which itself is a bit-field of the physical address
  // (mempool_tile.sv, tgt_group_id). So the mesh must be a power-of-two rectangle
  // and the group_xy_id_t field widths must sum EXACTLY to idx_width(NumGroups);
  // otherwise the cast silently mis-splits x from y rather than failing.
  if (NumX * NumY != NumGroups)
    $error("[%m] NumX*NumY does not equal NumGroups -- the mesh must tile the groups exactly.");
  if (NumX & (NumX - 1))
    $error("[%m] NumX must be a power of two (the group id is an address bit-field).");
  if (NumY & (NumY - 1))
    $error("[%m] NumY must be a power of two (the group id is an address bit-field).");
  if (idx_width(NumX) + idx_width(NumY) != idx_width(NumGroups))
    $error("[%m] idx_width(NumX)+idx_width(NumY) != idx_width(NumGroups) -- the group_xy_id_t bit-cast would mis-split the mesh coordinate.");

endmodule : terapool_cluster_floonoc_wrapper
