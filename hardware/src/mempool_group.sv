// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "mempool/mempool.svh"
`include "reqrsp_interface/typedef.svh"
`include "common_cells/registers.svh"

module mempool_group
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
#(
  // TCDM
  parameter addr_t       TCDMBaseAddr = 32'b0,
  // Boot address
  parameter logic [31:0] BootAddr     = 32'h0000_1000,
  // For post-synthesis
  parameter int unsigned GroupId      = 32'd0,
  // Enable the group-level MSHR in the remote request path.
  parameter bit          EnableGroupMshr = 1'b1,
  // Group-level fine-grained barrier (held-response TCDM slave). Integrated as a
  // DEDICATED extra output port of the group local interconnect (i_local_interco
  // NumOut = NumTilesPerGroup+1; see below). Default ON; disable with
  // -DGROUP_BARRIER_OFF (Makefile: group_barrier=0). A core ARRIVES+WAITS with a
  // local integer load to a same-group, DIFFERENT-tile address whose word field
  // == GroupBarrierWord + a fence; the load is routed (by the re-encoded tgt_sel)
  // to the barrier port, its response withheld until the core's pair rendezvous,
  // then driven back via the LIC (routed by ini_addr). The barrier must target a
  // different tile (a same-tile access is TCDM_LOCAL and never enters this xbar).
  // GroupBarrierWord is the reserved within-tile word (the master-port tgt_addr
  // word field = tgt_addr[TCDMAddrMemWidth +: ...]); with the barrier ON for ALL
  // apps the SW/linker MUST reserve this word group-wide so no data load aliases
  // it. Only sp-fmatmul is known clear of word 200.
`ifdef GROUP_BARRIER_OFF
  parameter bit          EnableGroupBarrier   = 1'b0,
`else
  parameter bit          EnableGroupBarrier   = 1'b1,
`endif
  parameter int unsigned NumGroupBarriers     = NumCoresPerGroup,
  // Single-cycle broadcast release for the group barrier (see mempool_group_barrier).
  // Default ON -- the legacy one-core-per-cycle release cost ~20 pp of FPU utilisation.
  // -DGROUP_BARRIER_BCAST_OFF restores the old staircase for A/B measurement.
  parameter bit          EnableBarrierBcast   =
    `ifdef GROUP_BARRIER_BCAST_OFF 1'b0 `else 1'b1 `endif,
  // Group-barrier watchdog, in cycles. 0 (default) = none: the barrier waits until every `target`
  // core arrives -- the intended rendezvous semantics. A non-zero value force-releases the arrived
  // subset after that many cycles, which desynchronizes rather than synchronizes; keep it 0 unless
  // you deliberately want a deadlock escape while debugging. Driven by group_barrier_wd_limit.
  parameter int unsigned GroupBarrierWdLimit  =
    `ifdef GROUP_BARRIER_WD_LIMIT `GROUP_BARRIER_WD_LIMIT `else 0 `endif,
  // Reserved within-tile word base (master-port tgt_addr word field). The barrier
  // owns words [GroupBarrierWord, GroupBarrierWord+NumGroupBarriers); struct =
  // word - GroupBarrierWord. SW forms a load at byte addr (word<<14)|(target_tile<<6),
  // target_tile = a same-group tile != own. The bank
  // field (byte[5:2]) selects the op: 0=arrive(load), 1=set target, 2=set mask.
  //
  // These words are STOLEN FROM THE DATA ADDRESS SPACE group-wide: any intra-group,
  // different-tile access whose word field lands here is re-routed to the barrier port
  // and its response is WITHHELD until a rendezvous that a data access never performs
  // -> silent deadlock. The linker MUST keep data out of the window; the l1 region in
  // software/runtime/arch.ld.c is truncated at GROUP_BARRIER_WORD<<14 to enforce it,
  // and `gbar_window_no_data_access` below fires if anything slips through.
  //
  // Default 240 (not 200): with NumGroupBarriers=16 and TCDMAddrMemWidth=8 (256 words)
  // the window [240,256) is exactly the TOP 16 words of L1, so the reservation costs a
  // trailing 256 KB instead of punching a hole in the middle of the data region. At
  // word 200 the hole sat at 0x320000, which a >3.125 MB working set cannot grow past
  // (a contiguous array cannot straddle it) -- that is what deadlocked 512x512x512.
  // MUST stay in sync with GBAR_BASE_WORD in the barrier-using software.
  parameter int unsigned GroupBarrierWord     =
    `ifdef GROUP_BARRIER_WORD `GROUP_BARRIER_WORD `else 240 `endif
) (
  // Clock and reset
  input  logic                                                                                   clk_i,
  input  logic                                                                                   rst_ni,
  input  logic                                                                                   testmode_i,
  // Scan chain
  input  logic                                                                                   scan_enable_i,
  input  logic                                                                                   scan_data_i,
  output logic                                                                                   scan_data_o,
  // Group ID
  input  logic                            [idx_width(NumGroups)-1:0]                             group_id_i,

  // TCDM Master interfaces
  output `STRUCT_VECT(tcdm_master_req_t,  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1])  tcdm_master_req_o,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   tcdm_master_req_valid_o,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   tcdm_master_req_ready_i,
  input  `STRUCT_VECT(tcdm_master_resp_t, [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]) tcdm_master_resp_i,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  tcdm_master_resp_valid_i,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  tcdm_master_resp_ready_o,
  // TCDM Slave interface
  input  `STRUCT_VECT(tcdm_slave_req_t,   [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1])  tcdm_slave_req_i,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   tcdm_slave_req_valid_i,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]   tcdm_slave_req_ready_o,
  output `STRUCT_VECT(tcdm_slave_resp_t,  [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]) tcdm_slave_resp_o,
  output logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  tcdm_slave_resp_valid_o,
  input  logic                            [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]  tcdm_slave_resp_ready_i,

  // Wake up interface
  input  logic                            [NumCoresPerGroup-1:0]                                 wake_up_i,
  // RO-Cache configuration
  input  `STRUCT_PORT(ro_cache_ctrl_t)                                                           ro_cache_ctrl_i,
  // DMA request
  input  `STRUCT_PORT(dma_req_t)                                                                 dma_req_i,
  input  logic                                                                                   dma_req_valid_i,
  output logic                                                                                   dma_req_ready_o,
  // DMA status
  output `STRUCT_PORT(dma_meta_t)                                                                dma_meta_o,
   // AXI Interface
  output `STRUCT_VECT(axi_tile_req_t,     [NumAXIMastersPerGroup-1:0])                           axi_mst_req_o,
  input  `STRUCT_VECT(axi_tile_resp_t,    [NumAXIMastersPerGroup-1:0])                           axi_mst_resp_i
);

  /*****************
   *  Definitions  *
   *****************/
  typedef logic [idx_width(NumTiles)-1:0] tile_id_t;

  /*********************
   *  Control Signals  *
   *********************/
  logic [NumCoresPerGroup-1:0] wake_up_q;
  `FF(wake_up_q, wake_up_i, '0, clk_i, rst_ni);

  ro_cache_ctrl_t ro_cache_ctrl_q;
  `FF(ro_cache_ctrl_q, ro_cache_ctrl_i, ro_cache_ctrl_default, clk_i, rst_ni);

  /***********
   *  Tiles  *
   ***********/
  // TCDM interfaces
  tcdm_master_req_t  [NumRemoteReqPortsPerTile-1:0] [NumTilesPerGroup-1:0] tcdm_master_req;
  logic              [NumRemoteReqPortsPerTile-1:0] [NumTilesPerGroup-1:0] tcdm_master_req_valid;
  logic              [NumRemoteReqPortsPerTile-1:0] [NumTilesPerGroup-1:0] tcdm_master_req_ready;
  tcdm_slave_req_t   [NumRemoteReqPortsPerTile-1:0] [NumTilesPerGroup-1:0] tcdm_slave_req;
  logic              [NumRemoteReqPortsPerTile-1:0] [NumTilesPerGroup-1:0] tcdm_slave_req_valid;
  logic              [NumRemoteReqPortsPerTile-1:0] [NumTilesPerGroup-1:0] tcdm_slave_req_ready;
  tcdm_master_resp_t [NumRemoteRespPortsPerTile-1:0][NumTilesPerGroup-1:0] tcdm_master_resp;
  logic              [NumRemoteRespPortsPerTile-1:0][NumTilesPerGroup-1:0] tcdm_master_resp_valid;
  logic              [NumRemoteRespPortsPerTile-1:0][NumTilesPerGroup-1:0] tcdm_master_resp_ready;
  tcdm_slave_resp_t  [NumRemoteRespPortsPerTile-1:0][NumTilesPerGroup-1:0] tcdm_slave_resp;
  logic              [NumRemoteRespPortsPerTile-1:0][NumTilesPerGroup-1:0] tcdm_slave_resp_valid;
  logic              [NumRemoteRespPortsPerTile-1:0][NumTilesPerGroup-1:0] tcdm_slave_resp_ready;

  // DMA interfaces
  tcdm_dma_req_t  [NumTilesPerGroup-1:0] tcdm_dma_req;
  logic           [NumTilesPerGroup-1:0] tcdm_dma_req_valid;
  logic           [NumTilesPerGroup-1:0] tcdm_dma_req_ready;
  tcdm_dma_resp_t [NumTilesPerGroup-1:0] tcdm_dma_resp;
  logic           [NumTilesPerGroup-1:0] tcdm_dma_resp_valid;
  logic           [NumTilesPerGroup-1:0] tcdm_dma_resp_ready;

  // AXI interfaces
  axi_tile_req_t  [NumTilesPerGroup-1:0] axi_tile_req;
  axi_tile_resp_t [NumTilesPerGroup-1:0] axi_tile_resp;
  axi_tile_req_t  [NumDmasPerGroup-1:0]  axi_dma_req;
  axi_tile_resp_t [NumDmasPerGroup-1:0]  axi_dma_resp;

  for (genvar t = 0; unsigned'(t) < NumTilesPerGroup; t++) begin: gen_tiles
    tile_id_t id;
    assign id = (group_id_i << $clog2(NumTilesPerGroup)) | t[idx_width(NumTilesPerGroup)-1:0];

    tcdm_master_req_t  [NumRemoteReqPortsPerTile-1:0]  tran_tcdm_master_req;
    logic              [NumRemoteReqPortsPerTile-1:0]  tran_tcdm_master_req_valid;
    logic              [NumRemoteReqPortsPerTile-1:0]  tran_tcdm_master_req_ready;
    tcdm_slave_req_t   [NumRemoteReqPortsPerTile-1:0]  tran_tcdm_slave_req;
    logic              [NumRemoteReqPortsPerTile-1:0]  tran_tcdm_slave_req_valid;
    logic              [NumRemoteReqPortsPerTile-1:0]  tran_tcdm_slave_req_ready;
    tcdm_master_resp_t [NumRemoteRespPortsPerTile-1:0] tran_tcdm_master_resp;
    logic              [NumRemoteRespPortsPerTile-1:0] tran_tcdm_master_resp_valid;
    logic              [NumRemoteRespPortsPerTile-1:0] tran_tcdm_master_resp_ready;
    tcdm_slave_resp_t  [NumRemoteRespPortsPerTile-1:0] tran_tcdm_slave_resp;
    logic              [NumRemoteRespPortsPerTile-1:0] tran_tcdm_slave_resp_valid;
    logic              [NumRemoteRespPortsPerTile-1:0] tran_tcdm_slave_resp_ready;

    mempool_tile #(
      .TCDMBaseAddr(TCDMBaseAddr),
      .BootAddr    (BootAddr    )
    ) i_tile (
      .clk_i                   (clk_i                                          ),
      .rst_ni                  (rst_ni                                         ),
      .scan_enable_i           (scan_enable_i                                  ),
      .scan_data_i             (/* Unconnected */                              ),
      .scan_data_o             (/* Unconnected */                              ),
      .tile_id_i               (id                                             ),
      // TCDM Master interfaces
      .tcdm_master_req_o       (tran_tcdm_master_req                           ),
      .tcdm_master_req_valid_o (tran_tcdm_master_req_valid                     ),
      .tcdm_master_req_ready_i (tran_tcdm_master_req_ready                     ),
      .tcdm_master_resp_i      (tran_tcdm_master_resp                          ),
      .tcdm_master_resp_valid_i(tran_tcdm_master_resp_valid                    ),
      .tcdm_master_resp_ready_o(tran_tcdm_master_resp_ready                    ),
      // TCDM banks interface
      .tcdm_slave_req_i        (tran_tcdm_slave_req                            ),
      .tcdm_slave_req_valid_i  (tran_tcdm_slave_req_valid                      ),
      .tcdm_slave_req_ready_o  (tran_tcdm_slave_req_ready                      ),
      .tcdm_slave_resp_o       (tran_tcdm_slave_resp                           ),
      .tcdm_slave_resp_valid_o (tran_tcdm_slave_resp_valid                     ),
      .tcdm_slave_resp_ready_i (tran_tcdm_slave_resp_ready                     ),
      // TCDM DMA interfaces
      .tcdm_dma_req_i          (tcdm_dma_req[t]                                ),
      .tcdm_dma_req_valid_i    (tcdm_dma_req_valid[t]                          ),
      .tcdm_dma_req_ready_o    (tcdm_dma_req_ready[t]                          ),
      .tcdm_dma_resp_o         (tcdm_dma_resp[t]                               ),
      .tcdm_dma_resp_valid_o   (tcdm_dma_resp_valid[t]                         ),
      .tcdm_dma_resp_ready_i   (tcdm_dma_resp_ready[t]                         ),
      // AXI interface
      .axi_mst_req_o           (axi_tile_req[t]                                ),
      .axi_mst_resp_i          (axi_tile_resp[t]                               ),
      // Wake up interface
      .wake_up_i               (wake_up_q[t*NumCoresPerTile +: NumCoresPerTile])
    );

    // Transpose the group requests
    for (genvar g = 0; g < NumRemoteReqPortsPerTile; g++) begin: gen_tran_group_req
      assign tcdm_master_req[g][t]          = tran_tcdm_master_req[g];
      assign tcdm_master_req_valid[g][t]    = tran_tcdm_master_req_valid[g];
      assign tran_tcdm_master_req_ready[g]  = tcdm_master_req_ready[g][t];
      assign tran_tcdm_slave_req[g]         = tcdm_slave_req[g][t];
      assign tran_tcdm_slave_req_valid[g]   = tcdm_slave_req_valid[g][t];
      assign tcdm_slave_req_ready[g][t]     = tran_tcdm_slave_req_ready[g];
    end: gen_tran_group_req

    for (genvar g = 0; g < NumRemoteRespPortsPerTile; g++) begin: gen_tran_group_resp
      assign tran_tcdm_master_resp[g]       = tcdm_master_resp[g][t];
      assign tran_tcdm_master_resp_valid[g] = tcdm_master_resp_valid[g][t];
      assign tcdm_master_resp_ready[g][t]   = tran_tcdm_master_resp_ready[g];
      assign tcdm_slave_resp[g][t]          = tran_tcdm_slave_resp[g];
      assign tcdm_slave_resp_valid[g][t]    = tran_tcdm_slave_resp_valid[g];
      assign tran_tcdm_slave_resp_ready[g]  = tcdm_slave_resp_ready[g][t];
    end: gen_tran_group_resp
  end : gen_tiles

  /*************************
   *  Local Interconnect  *
   *************************/

  // The local port is always at the index 0 out of the NumGroups TCDM ports of the tile.

  logic           [NumTilesPerGroup-1:0] master_local_req_valid;
  logic           [NumTilesPerGroup-1:0] master_local_req_ready;
  tcdm_addr_t     [NumTilesPerGroup-1:0] master_local_req_tgt_addr;
  logic           [NumTilesPerGroup-1:0] master_local_req_wen;
  tcdm_payload_t  [NumTilesPerGroup-1:0] master_local_req_wdata;
  strb_t          [NumTilesPerGroup-1:0] master_local_req_be;
  logic [NumTilesPerGroup-1:0][BurstLenWidth-1:0] master_local_req_burst_len;
  logic           [NumTilesPerGroup-1:0] master_local_resp_valid;
  logic           [NumTilesPerGroup-1:0] master_local_resp_ready;
  tcdm_payload_t  [NumTilesPerGroup-1:0] master_local_resp_rdata;
  logic           [NumTilesPerGroup-1:0] master_local_resp_wen;

  // Group-barrier BROADCAST release bypass (see mempool_group_barrier EnableBcast). Declared at
  // module scope because the mux sits on the per-tile response path above, while the driver is
  // inside the EnableGroupBarrier generate below.
  logic           [NumTilesPerGroup-1:0] bar_rel_vec;
  logic           [NumTilesPerGroup-1:0] bar_rel_ready;
  tcdm_payload_t  [NumTilesPerGroup-1:0] bar_rel_rdata;
  logic           [NumTilesPerGroup-1:0] slave_local_req_valid;
  logic           [NumTilesPerGroup-1:0] slave_local_req_ready;
  tile_addr_t     [NumTilesPerGroup-1:0] slave_local_req_tgt_addr;
  tile_group_id_t [NumTilesPerGroup-1:0] slave_local_req_ini_addr;
  logic           [NumTilesPerGroup-1:0] slave_local_req_wen;
  tcdm_payload_t  [NumTilesPerGroup-1:0] slave_local_req_wdata;
  strb_t          [NumTilesPerGroup-1:0] slave_local_req_be;
  logic           [NumTilesPerGroup-1:0] slave_local_resp_valid;
  logic           [NumTilesPerGroup-1:0] slave_local_resp_ready;
  tile_group_id_t [NumTilesPerGroup-1:0] slave_local_resp_ini_addr;
  tcdm_payload_t  [NumTilesPerGroup-1:0] slave_local_resp_rdata;
  logic           [NumTilesPerGroup-1:0] slave_local_resp_wen;

  // Group barrier = a dedicated extra OUTPUT PORT of i_local_interco at index
  // NumTilesPerGroup (the 16 tiles keep ports 0..15). Each master's 16-bit tgt_addr
  // is re-encoded to a (TCDMAddrWidth+1)-bit LIC address: a 0 is inserted just above
  // the tile-select field, so tiles keep tgt_sel={1'b0,tile} + mem-addr unchanged;
  // a barrier request (word field == GroupBarrierWord) instead forces tgt_sel =
  // NumTilesPerGroup -> the barrier port. The held response returns via the LIC's
  // normal resp routing (by ini_addr) -- no master-side injection needed.
  localparam int unsigned LicNumOut    = NumTilesPerGroup + 1;
  localparam int unsigned LicAddrWidth = TCDMAddrWidth + 1;
  localparam int unsigned TileSelW     = idx_width(NumTilesPerGroup);
  logic [NumTilesPerGroup-1:0]                   bar_sel;
  logic [NumTilesPerGroup-1:0][LicAddrWidth-1:0] req_tgt_addr_lic;
  // barrier output-port (index NumTilesPerGroup) request/response signals
  logic           bar_req_valid, bar_req_ready, bar_req_wen;
  tile_group_id_t bar_req_ini;
  tile_addr_t     bar_req_tgt_addr;
  tcdm_payload_t  bar_req_wdata;
  // Group MSHR runtime configuration, written through the barrier port's bank==3 op encoding.
  // Declared here (not inside gen_group_barrier) so the MSHR instantiation can connect them in
  // every arm; with the barrier disabled they stay tied off and the CSR file folds to its defaults.
  logic        bar_is_cfg, bar_ext_rd;
  logic        mshr_cfg_wr_valid;
  logic [3:0]  mshr_cfg_wr_idx;
  logic [31:0] mshr_cfg_wr_data;
  mshr_cfg_t   mshr_cfg;
  logic [31:0] mshr_cfg_status;
  logic        mshr_busy;
  strb_t          bar_req_be;
  logic           bar_resp_valid, bar_resp_ready, bar_resp_wen;
  tile_group_id_t bar_resp_ini;
  tcdm_payload_t  bar_resp_rdata;

  for (genvar t = 0; t < NumTilesPerGroup; t++) begin: gen_local_connections
    assign master_local_req_valid[t]          = tcdm_master_req_valid[0][t];
    assign master_local_req_tgt_addr[t]       = tcdm_master_req[0][t].tgt_addr;
    assign master_local_req_wen[t]            = tcdm_master_req[0][t].wen;
    assign master_local_req_wdata[t]          = tcdm_master_req[0][t].wdata;
    assign master_local_req_be[t]             = tcdm_master_req[0][t].be;
    assign master_local_req_burst_len[t]      = tcdm_master_req[0][t].burst_len;
    assign tcdm_master_req_ready[0][t]        = master_local_req_ready[t];
    assign slave_local_resp_valid[t]          = tcdm_slave_resp_valid[0][t];
    assign slave_local_resp_ini_addr[t]       = tcdm_slave_resp[0][t].ini_addr;
    assign slave_local_resp_rdata[t]          = tcdm_slave_resp[0][t].rdata;
    assign slave_local_resp_wen[t]            = tcdm_slave_resp[0][t].wen;
    assign tcdm_slave_resp_ready[0][t]        = slave_local_resp_ready[t];
    // The barrier's broadcast release is merged in HERE rather than routed through the LIC:
    // the LIC response carries a single resp_ini_addr, so it can only release one core per
    // cycle -- a 16-cycle staircase, wider than the ~10-15 cyc MSHR merge window the barrier
    // exists to hit (worth ~20 pp of FPU utilisation). The release is a dummy load writeback
    // carrying only meta_id/core_id, so merging it costs one 2:1 mux per tile and NO extra
    // crossbar port. The barrier wins the cycle; the LIC response is held off via ready and
    // retries next cycle (it is a normal back-pressured stream, so this is lossless).
    assign tcdm_master_resp_valid[0][t]       = bar_rel_vec[t] | master_local_resp_valid[t];
    assign tcdm_master_resp[0][t].rdata       = bar_rel_vec[t] ? bar_rel_rdata[t]
                                                              : master_local_resp_rdata[t];
    assign tcdm_master_resp[0][t].wen         = bar_rel_vec[t] ? 1'b0 : master_local_resp_wen[t];
    // Port 0 is the LOCAL path: the remote ports are declared [N-1:1] and the port->array loops
    // start at r=1, so nothing upstream ever writes index [0]. Tie the MSHR tag off explicitly --
    // the group MSHR only sees ports 1.., so the field is unused here (same rationale as the
    // tile's own local tie-offs, mempool_tile.sv:1201/1207), but leaving it undriven puts an X on
    // a struct that crosses into the tile.
    assign tcdm_master_resp[0][t].mshr_tag    = '0;
    assign master_local_resp_ready[t]         = tcdm_master_resp_ready[0][t] & ~bar_rel_vec[t];
    assign bar_rel_ready[t]                   = tcdm_master_resp_ready[0][t];
    assign tcdm_slave_req_valid[0][t]         = slave_local_req_valid[t];
    assign tcdm_slave_req[0][t].tgt_addr      = slave_local_req_tgt_addr[t];
    assign tcdm_slave_req[0][t].ini_addr      = slave_local_req_ini_addr[t];
    assign tcdm_slave_req[0][t].wen           = slave_local_req_wen[t];
    assign tcdm_slave_req[0][t].wdata         = slave_local_req_wdata[t];
    assign tcdm_slave_req[0][t].be            = slave_local_req_be[t];
    // The local interconnect does not carry burst_len sideband. Rebuild it from
    // the selected initiator index (req_ini_addr) to preserve local burst metadata.
    assign tcdm_slave_req[0][t].burst_len     =
      slave_local_req_valid[t] ? master_local_req_burst_len[slave_local_req_ini_addr[t]]
                               : BurstLenWidth'(1);
    assign tcdm_slave_req[0][t].src_group_id  = group_id_i;
    assign tcdm_slave_req[0][t].mshr_tag      = '0; // Tier-b: local path unused (see resp above)
    assign slave_local_req_ready[t]           = tcdm_slave_req_ready[0][t];
  end

  // Re-encode each master's target address for the widened (NumOut+1) LIC: insert a
  // 0 just above the tile-select so the 16 tiles keep tgt_sel={1'b0,tile} + mem-addr
  // unchanged; a barrier word forces tgt_sel = NumTilesPerGroup (the barrier port).
  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_bar_addr_remap
    // barrier window = words [GroupBarrierWord, GroupBarrierWord+NumGroupBarriers)
    // The bounds are compared ONE BIT WIDER than the word field. The upper bound
    // GroupBarrierWord+NumGroupBarriers can legitimately equal 2**TCDMAddrMemWidth (the window
    // ending exactly at the top of the bank, e.g. 240+16 = 256 with an 8-bit word field); casting
    // it to TCDMAddrMemWidth would truncate it to 0, making `word < 0` always false and silently
    // DISABLING the barrier for every access. That is not hypothetical: it cost a 2x matmul
    // slowdown (the per-iteration group barrier stopped synchronizing, so cores drifted apart)
    // before being caught. Zero-extending both sides keeps the compare exact.
    assign bar_sel[t] = EnableGroupBarrier &&
      ({1'b0, master_local_req_tgt_addr[t][TCDMAddrWidth-1 -: TCDMAddrMemWidth]} >=
       (TCDMAddrMemWidth+1)'(GroupBarrierWord)) &&
      ({1'b0, master_local_req_tgt_addr[t][TCDMAddrWidth-1 -: TCDMAddrMemWidth]} <
       (TCDMAddrMemWidth+1)'(GroupBarrierWord + NumGroupBarriers));
    assign req_tgt_addr_lic[t] = bar_sel[t]
      // barrier: tgt_sel = NumTilesPerGroup (port 16); pass {word,bank} as the mem-addr
      // so the adapter can decode struct (word-base) + op (bank).
      ? { master_local_req_tgt_addr[t][TCDMAddrWidth-1 : TileSelW], (TileSelW+1)'(NumTilesPerGroup) }
      : { master_local_req_tgt_addr[t][TCDMAddrWidth-1 : TileSelW],   // {word,bank} = mem-addr
          1'b0,                                                        // inserted barrier-select bit
          master_local_req_tgt_addr[t][TileSelW-1 : 0] };             // tile = LIC output select
  end

  // Data-alias tripwire for the reserved barrier window.
  //
  // The barrier's own ops span BOTH directions: bank0 = arrive (LOAD), bank1 = set target
  // (STORE), bank2 = set mask (STORE) -- see gbar_setup() in the barrier-using software. So
  // loads and stores are both legitimate in this window and must NOT be flagged; doing so
  // would $fatal on correct barrier configuration.
  //
  // An **AMO** is never a barrier op, so an AMO landing in [GroupBarrierWord, +NumGroupBarriers)
  // can only be ordinary data that the linker failed to keep out of the window. It is re-routed
  // to the barrier port and has its response withheld forever, deadlocking the core with NO
  // other symptom (no MSHR entry, no orphan response, no backpressure: nothing else sees it).
  // This fires at the exact cycle of the aliasing access instead of leaving a silent hang; the
  // 512x512x512 failure was `amoadd.w` on the runtime `barrier` word.
  //
  // Coverage caveat: this catches the AMO case only. A plain load/store alias is
  // indistinguishable from a real barrier op here and stays silent -- the linker reservation in
  // software/runtime/arch.ld.c is the actual guarantee; this is only a backstop.
  // NOTE: Verilator ignores SVA unless run with --assert, so this is effective under
  // QuestaSim/VCS but inert in the default Verilator flow.
  // Elaboration guard: the window must fit inside the word field and must not be empty.
  // A window that runs past 2**TCDMAddrMemWidth would wrap and disable the barrier silently.
  if (EnableGroupBarrier) begin : gen_gbar_window_check
    if (GroupBarrierWord + NumGroupBarriers > (1 << TCDMAddrMemWidth))
      $fatal(1, "GroupBarrierWord(%0d)+NumGroupBarriers(%0d) exceeds the %0d-word bank (max %0d).",
             GroupBarrierWord, NumGroupBarriers, 1 << TCDMAddrMemWidth, 1 << TCDMAddrMemWidth);
    if (NumGroupBarriers == 0)
      $fatal(1, "NumGroupBarriers must be > 0 when EnableGroupBarrier is set.");
  end

`ifndef TARGET_SYNTHESIS
  if (EnableGroupBarrier) begin : gen_gbar_alias_check
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_gbar_alias_tile
      gbar_window_no_amo_alias: assert property (@(posedge clk_i) disable iff (!rst_ni)
          (master_local_req_valid[t] && bar_sel[t])
            |-> (master_local_req_wdata[t].amo == '0))
        else $fatal(1,
          {"GROUP BARRIER WINDOW ALIASED BY DATA: tile %0d issued an AMO to reserved word %0d ",
           "(window [%0d,%0d)). The linker placed data in the barrier window; this request is ",
           "re-routed to the barrier port and its response is withheld forever. Keep data below ",
           "GROUP_BARRIER_WORD<<14 -- see the l1 region in software/runtime/arch.ld.c."},
          t, master_local_req_tgt_addr[t][TCDMAddrWidth-1 -: TCDMAddrMemWidth],
          GroupBarrierWord, GroupBarrierWord + NumGroupBarriers);
    end
  end
`endif

  variable_latency_interconnect #(
    .NumIn            (NumTilesPerGroup                             ),
    .NumOut           (LicNumOut                                    ),  // +1 = barrier slave port
    .AddrWidth        (LicAddrWidth                                 ),  // +1 select bit
    .DataWidth        ($bits(tcdm_payload_t)                        ),
    .BeWidth          (DataWidth/8                                  ),
    .ByteOffWidth     (0                                            ),
    .AddrMemWidth     (TCDMAddrMemWidth + idx_width(NumBanksPerTile)),
    .Topology         (tcdm_interconnect_pkg::LIC                   ),
    // The local interconnect needs no extra spill registers
    .SpillRegisterReq (64'b0                                        ),
    .SpillRegisterResp(64'b0                                        ),
    .AxiVldRdy        (1'b1                                         )
  ) i_local_interco (
    .clk_i          (clk_i                    ),
    .rst_ni         (rst_ni                   ),
    .req_valid_i    (master_local_req_valid   ),
    .req_ready_o    (master_local_req_ready   ),
    .req_tgt_addr_i (req_tgt_addr_lic         ),
    .req_wen_i      (master_local_req_wen     ),
    .req_wdata_i    (master_local_req_wdata   ),
    .req_be_i       (master_local_req_be      ),
    .resp_valid_o   (master_local_resp_valid  ),
    .resp_ready_i   (master_local_resp_ready  ),
    .resp_rdata_o   (master_local_resp_rdata  ),
  `ifdef TARGET_SPATZ
    .resp_write_o   (master_local_resp_wen          ),
    .resp_write_i   ({bar_resp_wen,   slave_local_resp_wen}     ),
  `endif
    // Barrier is output port index NumTilesPerGroup (MSB of each {bar,tiles} concat).
    .resp_ini_addr_i({bar_resp_ini,   slave_local_resp_ini_addr}),
    .resp_rdata_i   ({bar_resp_rdata, slave_local_resp_rdata}   ),
    .resp_valid_i   ({bar_resp_valid, slave_local_resp_valid}   ),
    .resp_ready_o   ({bar_resp_ready, slave_local_resp_ready}   ),
    .req_valid_o    ({bar_req_valid,  slave_local_req_valid}    ),
    .req_ready_i    ({bar_req_ready,  slave_local_req_ready}    ),
    .req_be_o       ({bar_req_be,     slave_local_req_be}       ),
    .req_wdata_o    ({bar_req_wdata,  slave_local_req_wdata}    ),
    .req_wen_o      ({bar_req_wen,    slave_local_req_wen}      ),
    .req_ini_addr_o ({bar_req_ini,    slave_local_req_ini_addr} ),
    .req_tgt_addr_o ({bar_req_tgt_addr, slave_local_req_tgt_addr})
  );

  /*****************************************
   *  Group-level fine-grained barrier     *
   *  (held-response slave on LIC port N)  *
   *****************************************/
  // The barrier is i_local_interco output port index NumTilesPerGroup. The LIC
  // already arbitrates <=1 arrive/cycle to it (its per-output rr_arb_tree) and
  // routes the held response back to the requesting master by ini_addr -- so no
  // external arbiter and no response injection are needed. The adapter only:
  // accepts immediately (req_ready=1, defer just the response), captures each
  // arrive's payload to echo meta_id/core_id on release (so the requesting core's
  // integer LSU matches the response to its held lw), and drives the rendezvous
  // unit's release onto the barrier port's response channel.
  if (EnableGroupBarrier) begin : gen_group_barrier
    localparam int unsigned BarStructW = (NumGroupBarriers > 1) ? $clog2(NumGroupBarriers) : 1;
    localparam int unsigned BankW      = idx_width(NumBanksPerTile);
    tcdm_payload_t  [NumTilesPerGroup-1:0] meta_store_q;
    logic           [NumGroupBarriers-1:0] bar_wd_fire;
    logic                                  bar_core_resp_valid, bar_core_resp_wen;
    tile_group_id_t                        bar_core_resp_ini;
    // decode struct + op from the barrier-port mem-addr ({word,bank}) and wen.
    logic [TCDMAddrMemWidth-1:0] bar_word;
    logic [BankW-1:0]            bar_bank;
    logic [BarStructW-1:0]       bar_struct;
    logic [1:0]                  bar_op;  // 0=ARRIVE(load), 1=WR_TARGET, 2=WR_MASK
    assign bar_word   = bar_req_tgt_addr[TCDMAddrMemWidth + BankW - 1 : BankW];  // word field
    assign bar_bank   = bar_req_tgt_addr[BankW-1 : 0];                           // bank field = op
    assign bar_struct = BarStructW'(bar_word - TCDMAddrMemWidth'(GroupBarrierWord));
    // Bank encoding 3 carries the group MSHR CSR file, reusing bar_struct as the CSR index: 16 CSRs
    // x 32 bits on an ALREADY-DECODED group-level port, so no new address space and no new crossbar
    // decode. See docs/mshr_runtime_csr_design.md.
    //
    // CORRECTION (2026-08-15). An earlier version of this comment said struct N with bank 1 and
    // struct N with bank 3 "never collide because the op distinguishes them". That was FALSE and it
    // hung the design: banks 0/2/3 all fell into the same `else` and issued OP_WR_MASK, so a CSR
    // write executed mask_d[bar_struct] = data on the BARRIER, clobbering the struct whose index
    // equalled the CSR index. Claiming a spare *field value* is not enough -- the consumer's decode
    // has to be given the new case too, which is what OP_EXT_ACK (2'd3) below does.
    assign mshr_cfg_wr_valid = bar_req_valid && bar_req_ready && bar_req_wen &&
                               (bar_bank == BankW'(3));
    assign mshr_cfg_wr_idx   = 4'(bar_struct);
    assign mshr_cfg_wr_data  = 32'(bar_req_wdata.data);
    // bank 3 MUST get its own encoding, for BOTH directions.
    //
    // Write side: bank 3 used to fall through to 2'd2 (OP_WR_MASK), so every MSHR CSR write also
    // overwrote barrier struct bar_struct's mask -- and bar_struct is the CSR index, so writing
    // CSRs 0..8,15 clobbered barrier structs 0..8,15, and mempool_barrier() hung on a mask nobody set.
    //
    // Read side: a read (wen=0) hit the FIRST ternary and became OP_ARRIVE regardless of bank, so
    // the CFG_STATUS read-back at the end of mshr_cfg_apply_group() was a barrier ARRIVAL. One core
    // per group arrived at a struct needing all 16, nothing ever released, and the read never
    // returned -- 16 stuck loads, one per group. Both were found by V3 on 2026-08-15; fixing only
    // the write side left the design hung in exactly the same shape, which is why the read side is
    // called out separately here.
    assign bar_is_cfg = (bar_bank == BankW'(3));
    assign bar_ext_rd = bar_is_cfg && !bar_req_wen;
    assign bar_op     = bar_is_cfg              ? 2'd3   // OP_EXT_ACK, read or write
                      : (!bar_req_wen)          ? 2'd0
                      : (bar_bank == BankW'(1)) ? 2'd1
                      : 2'd2;

    // capture each accepted request's payload, to echo meta_id/core_id on the
    // response (release OR config-write ack). Gated by req_ready (= !ack_pending),
    // so a 2nd config write can't overwrite a pending ack's meta.
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)                             meta_store_q              <= '0;
      else if (bar_req_valid && bar_req_ready) meta_store_q[bar_req_ini] <= bar_req_wdata;
    end

    // general-purpose, memory-mapped rendezvous unit (NumGroupBarriers structs).
    mempool_group_barrier #(
      .NumCoresPerGroup(NumTilesPerGroup   ),
      .NumBarriers     (NumGroupBarriers   ),
      .WatchdogLimit   (GroupBarrierWdLimit),
      .EnableBcast     (EnableBarrierBcast )
    ) i_group_barrier (
      .clk_i, .rst_ni,
      .req_valid_i    (bar_req_valid      ),
      .req_ini_addr_i (bar_req_ini        ),
      .req_op_i       (bar_op             ),
      .req_ext_rd_i   (bar_ext_rd         ),
      .req_struct_i   (bar_struct         ),
      .req_cfg_data_i (bar_req_wdata.data[NumTilesPerGroup-1:0]),
      .req_ready_o    (bar_req_ready      ),
      .resp_valid_o   (bar_core_resp_valid),
      .resp_ini_addr_o(bar_core_resp_ini  ),
      .resp_wen_o     (bar_core_resp_wen  ),
      .resp_ready_i   (bar_resp_ready     ),
      .rel_vec_o      (bar_rel_vec        ),
      .rel_ready_i    (bar_rel_ready      ),
      .wd_fire_o      (bar_wd_fire        )
    );

    // Broadcast-release payload, one per core: the same echoed meta the LIC path builds, but
    // indexed by the core being released rather than by a single resp_ini_addr.
    for (genvar c = 0; c < NumTilesPerGroup; c++) begin : gen_bar_rel_rdata
      assign bar_rel_rdata[c] = '{meta_id: meta_store_q[c].meta_id,
                                  core_id: meta_store_q[c].core_id,
                                  amo: '0, data: '0};
    end

    // drive the held response / config-write ack onto the barrier port; the LIC
    // routes it to the requesting master by ini_addr. resp_wen=1 (config ack) frees
    // the store id (no writeback); resp_wen=0 (release) writes back the dummy load.
    assign bar_resp_valid = bar_core_resp_valid;
    assign bar_resp_ini   = bar_core_resp_ini;
    assign bar_resp_wen   = bar_core_resp_wen;
    // Track whether the ack currently in flight belongs to a CSR READ, so its response carries the
    // status word. req_ready is gated on !ack_pending, so at most one is outstanding and a single
    // flag suffices. A barrier release still writes back the dummy zero it always did.
    logic cfg_rd_pend_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni)                                    cfg_rd_pend_q <= 1'b0;
      else if (bar_req_valid && bar_req_ready && bar_ext_rd) cfg_rd_pend_q <= 1'b1;
      else if (bar_resp_valid && bar_resp_ready)      cfg_rd_pend_q <= 1'b0;
    end
    assign bar_resp_rdata = '{meta_id: meta_store_q[bar_core_resp_ini].meta_id,
                              core_id: meta_store_q[bar_core_resp_ini].core_id,
                              amo: '0,
                              data: cfg_rd_pend_q ? mshr_cfg_status : '0};
  end else begin : gen_no_group_barrier
    // Barrier port present but never selected (bar_sel forced 0); tie it off. The MSHR CSR write
    // port rides the same decode, so it ties off here too -- the CSR file then folds to its
    // elaborated defaults, which is exactly the pre-CSR behaviour.
    assign mshr_cfg_wr_valid = 1'b0;
    assign mshr_cfg_wr_idx   = '0;
    assign mshr_cfg_wr_data  = '0;
    assign bar_is_cfg     = 1'b0;
    assign bar_ext_rd     = 1'b0;
    assign bar_req_ready  = 1'b1;
    assign bar_resp_valid = 1'b0;
    assign bar_resp_ini   = '0;
    assign bar_resp_wen   = 1'b0;
    assign bar_resp_rdata = '0;
    assign bar_rel_vec    = '0;                 // broadcast bypass inert: mux selects the LIC
    assign bar_rel_rdata  = '0;
  end

  /**************************
   *  Remote Interconnects  *
   **************************/

  // Group-level MSHR wiring (remote ports only).
  tcdm_master_req_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]  group_mshr_req;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]  group_mshr_req_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]  group_mshr_req_ready;
  tcdm_master_req_t  [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]  mshr_noc_req;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]  mshr_noc_req_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteReqPortsPerTile-1:1]  mshr_noc_req_ready;
  tcdm_master_resp_t [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] mshr_noc_resp;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] mshr_noc_resp_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] mshr_noc_resp_ready;
  tcdm_master_resp_t [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] group_mshr_resp;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] group_mshr_resp_valid;
  logic              [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1] group_mshr_resp_ready;

  // Sort the remote ports by tile
  for (genvar r = 1; r < NumRemoteReqPortsPerTile; r++) begin: gen_remote_interface_connection_req
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin: gen_remote_connections_req
      // master req
      assign group_mshr_req_valid[t][r]     = tcdm_master_req_valid[r][t];
      assign group_mshr_req[t][r]           = tcdm_master_req[r][t];
      assign tcdm_master_req_ready[r][t]    = group_mshr_req_ready[t][r];
      assign tcdm_master_req_valid_o[t][r]  = mshr_noc_req_valid[t][r];
      assign tcdm_master_req_o[t][r]        = mshr_noc_req[t][r];
      assign mshr_noc_req_ready[t][r]       = tcdm_master_req_ready_i[t][r];
      // slave req
      assign tcdm_slave_req[r][t]           = tcdm_slave_req_i[t][r];
      assign tcdm_slave_req_valid[r][t]     = tcdm_slave_req_valid_i[t][r];
      assign tcdm_slave_req_ready_o[t][r]   = tcdm_slave_req_ready[r][t];
    end: gen_remote_connections_req
  end: gen_remote_interface_connection_req

  for (genvar r = 1; r < NumRemoteRespPortsPerTile; r++) begin: gen_remote_interface_connection_resp
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin: gen_remote_connections_resp
      // master resp
      assign mshr_noc_resp[t][r]            = tcdm_master_resp_i[t][r];
      assign mshr_noc_resp_valid[t][r]      = tcdm_master_resp_valid_i[t][r];
      assign tcdm_master_resp_ready_o[t][r] = mshr_noc_resp_ready[t][r];
      assign tcdm_master_resp[r][t]         = group_mshr_resp[t][r];
      assign tcdm_master_resp_valid[r][t]   = group_mshr_resp_valid[t][r];
      assign group_mshr_resp_ready[t][r]    = tcdm_master_resp_ready[r][t];
      // slave resp
      assign tcdm_slave_resp_o[t][r]        = tcdm_slave_resp[r][t];
      assign tcdm_slave_resp_valid_o[t][r]  = tcdm_slave_resp_valid[r][t];
      assign tcdm_slave_resp_ready[r][t]    = tcdm_slave_resp_ready_i[t][r];
    end: gen_remote_connections_resp
  end: gen_remote_interface_connection_resp

  /**********************
   *  AXI Interconnect  *
   **********************/

  axi_tile_req_t   [NumAXIMastersPerGroup-1:0] axi_mst_req;
  axi_tile_resp_t  [NumAXIMastersPerGroup-1:0] axi_mst_resp;
  axi_tile_req_t  [NumTilesPerGroup+NumDmasPerGroup-1:0] axi_slv_req;
  axi_tile_resp_t [NumTilesPerGroup+NumDmasPerGroup-1:0] axi_slv_resp;

`ifdef WAKEUP_PROBE
  // Does the group's AXI master (icache refill out of the RO cache) actually emit the
  // read that the stalled core is waiting on? At 8x8 core 0 stalls fetching 0x800014e0,
  // which the 2 KB L2 stripe maps to channel 2 -- a channel the L2 probe shows is never
  // touched. Splits the remaining space: no AR emitted => the fault is inside the RO
  // cache / axi_to_cache; AR emitted with no R => the NoC path to that endpoint.
  integer gax_ar, gax_r, gax_cyc;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      gax_ar <= 0; gax_r <= 0; gax_cyc <= 0;
    end else begin
      gax_cyc <= gax_cyc + 1;
      for (int m = 0; m < NumAXIMastersPerGroup; m++) begin
        if (axi_mst_req[m].ar_valid && axi_mst_resp[m].ar_ready) begin
          gax_ar <= gax_ar + 1;
          if (axi_mst_req[m].ar.addr[31:20] != 12'h800)
            $display("[GAX] grp %0d cyc %0d AR addr=%h (beyond channel 0/1)",
                     group_id_i, gax_cyc, axi_mst_req[m].ar.addr);
        end
        if (axi_mst_resp[m].r_valid && axi_mst_req[m].r_ready) gax_r <= gax_r + 1;
      end
      if (gax_cyc % 4000 == 0 && group_id_i < 3)
        $display("[GAX] grp %0d cyc %0d  ar=%0d r=%0d", group_id_i, gax_cyc, gax_ar, gax_r);
    end
  end
`endif

  for (genvar i = 0; i < NumDmasPerGroup; i++) begin : gen_axi_slv_vec
    assign axi_slv_req[i*(NumTilesPerDma+1)+:NumTilesPerDma+1] = {axi_dma_req[i],axi_tile_req[i*NumTilesPerDma+:NumTilesPerDma]};
    assign {axi_dma_resp[i],axi_tile_resp[i*NumTilesPerDma+:NumTilesPerDma]} = axi_slv_resp[i*(NumTilesPerDma+1)+:NumTilesPerDma+1];
  end : gen_axi_slv_vec

  axi_hier_interco #(
    .NumSlvPorts    (NumTilesPerGroup+NumDmasPerGroup),
    .NumMstPorts    (NumAXIMastersPerGroup           ),
    .Radix          (AxiHierRadix                    ),
    .EnableCache    (32'hFFFFFFFF                    ),
    .CacheLineWidth (ROCacheLineWidth                ),
    .CacheSizeByte  (ROCacheSizeByte                 ),
    .CacheSets      (ROCacheSets                     ),
    .AddrWidth      (AddrWidth                       ),
    .DataWidth      (AxiDataWidth                    ),
    .SlvIdWidth     (AxiTileIdWidth                  ),
    .MstIdWidth     (AxiTileIdWidth                  ),
    .UserWidth      (1                               ),
    .slv_req_t      (axi_tile_req_t                  ),
    .slv_resp_t     (axi_tile_resp_t                 ),
    .mst_req_t      (axi_tile_req_t                  ),
    .mst_resp_t     (axi_tile_resp_t                 )
  ) i_axi_interco (
    .clk_i           (clk_i          ),
    .rst_ni          (rst_ni         ),
    .test_i          (1'b0           ),
    .ro_cache_ctrl_i (ro_cache_ctrl_q),
    .slv_req_i       (axi_slv_req    ),
    .slv_resp_o      (axi_slv_resp   ),
    .mst_req_o       (axi_mst_req    ),
    .mst_resp_i      (axi_mst_resp   )
  );

  for (genvar m = 0; m < NumAXIMastersPerGroup; m++) begin: gen_axi_group_cuts
    axi_cut #(
      .ar_chan_t (axi_tile_ar_t  ),
      .aw_chan_t (axi_tile_aw_t  ),
      .r_chan_t  (axi_tile_r_t   ),
      .w_chan_t  (axi_tile_w_t   ),
      .b_chan_t  (axi_tile_b_t   ),
      .axi_req_t (axi_tile_req_t ),
      .axi_resp_t(axi_tile_resp_t)
    ) i_axi_cut (
      .clk_i     (clk_i            ),
      .rst_ni    (rst_ni           ),
      .slv_req_i (axi_mst_req[m]   ),
      .slv_resp_o(axi_mst_resp[m]  ),
      .mst_req_o (axi_mst_req_o[m] ),
      .mst_resp_i(axi_mst_resp_i[m])
    );
  end: gen_axi_group_cuts

  /*********
   *  DMA  *
   *********/
  dma_req_t  dma_req_cut;
  logic      dma_req_cut_valid;
  logic      dma_req_cut_ready;
  dma_meta_t dma_meta_cut;

  spill_register #(
    .T(dma_req_t)
  ) i_dma_req_register (
    .clk_i  (clk_i            ),
    .rst_ni (rst_ni           ),
    .data_i (dma_req_i        ),
    .valid_i(dma_req_valid_i  ),
    .ready_o(dma_req_ready_o  ),
    .data_o (dma_req_cut      ),
    .valid_o(dma_req_cut_valid),
    .ready_i(dma_req_cut_ready)
  );

  `FF(dma_meta_o, dma_meta_cut, '0, clk_i, rst_ni);

  dma_req_t  [NumDmasPerGroup-1:0] dma_req;
  logic      [NumDmasPerGroup-1:0] dma_req_valid;
  logic      [NumDmasPerGroup-1:0] dma_req_ready;
  dma_meta_t [NumDmasPerGroup-1:0] dma_meta;

  idma_distributed_midend #(
    .NoMstPorts     (NumDmasPerGroup                   ),
    .DmaRegionWidth (NumBanksPerGroup*4/NumDmasPerGroup),
    .DmaRegionStart (TCDMBaseAddr                      ),
    .DmaRegionEnd   (TCDMBaseAddr+TCDMSize             ),
    .TransFifoDepth (16                                ),
    .burst_req_t    (dma_req_t                         ),
    .meta_t         (dma_meta_t                        )
  ) i_idma_distributed_midend (
    .clk_i       (clk_i            ),
    .rst_ni      (rst_ni           ),
    .burst_req_i (dma_req_cut      ),
    .valid_i     (dma_req_cut_valid),
    .ready_o     (dma_req_cut_ready),
    .meta_o      (dma_meta_cut     ),
    .burst_req_o (dma_req          ),
    .valid_o     (dma_req_valid    ),
    .ready_i     (dma_req_ready    ),
    .meta_i      (dma_meta         )
  );

  // xbar
  localparam int unsigned NumRules = 1;
  typedef struct packed {
    int unsigned idx;
    logic [AddrWidth-1:0] start_addr;
    logic [AddrWidth-1:0] end_addr;
  } xbar_rule_t;
  xbar_rule_t [NumRules-1:0] addr_map;
  assign addr_map = '{
    '{ // TCDM
      start_addr: TCDMBaseAddr,
      end_addr:   TCDMBaseAddr + TCDMSize,
      idx:        1
    }
  };

  `REQRSP_TYPEDEF_ALL(reqrsp, addr_t, axi_data_t, axi_strb_t)
  logic        [NumDmasPerGroup-1:0][idx_width(NumTilesPerDma)-1:0] tile_id_remap;

  for (genvar d = 0; unsigned'(d) < NumDmasPerGroup; d++) begin: gen_dmas
    localparam int unsigned a = NumTilesPerGroup + d;

    axi_tile_req_t  axi_dma_premux_req;
    axi_tile_resp_t axi_dma_premux_resp;
    axi_tile_req_t  tcdm_req;
    axi_tile_resp_t tcdm_resp;

    logic backend_idle;
    logic trans_complete;

    axi_dma_backend #(
      .DataWidth       (AxiDataWidth   ),
      .AddrWidth       (AddrWidth      ),
      .IdWidth         (AxiTileIdWidth ),
      .AxReqFifoDepth  (8              ),
      .TransFifoDepth  (1              ),
      .BufferDepth     (4              ),
      .axi_req_t       (axi_tile_req_t ),
      .axi_res_t       (axi_tile_resp_t),
      .burst_req_t     (dma_req_t      ),
      .DmaIdWidth      (1              ),
      .DmaTracing      (0              )
    ) i_axi_dma_backend (
      .clk_i            (clk_i                     ),
      .rst_ni           (rst_ni                    ),
      .dma_id_i         (1'b0                      ),
      .axi_dma_req_o    (axi_dma_premux_req        ),
      .axi_dma_res_i    (axi_dma_premux_resp       ),
      .burst_req_i      (dma_req[d]                ),
      .valid_i          (dma_req_valid[d]          ),
      .ready_o          (dma_req_ready[d]          ),
      .backend_idle_o   (dma_meta[d].backend_idle  ),
      .trans_complete_o (dma_meta[d].trans_complete)
    );

    // ------------------------------------------------------
    // AXI connection to EXT/TCDM
    // ------------------------------------------------------

    localparam axi_pkg::xbar_cfg_t XbarCfg = '{
      NoSlvPorts:         1,
      NoMstPorts:         2,
      MaxMstTrans:        8,
      MaxSlvTrans:        8,
      FallThrough:        1'b0,
      LatencyMode:        axi_pkg::CUT_ALL_PORTS,
      PipelineStages:     0,
      AxiIdWidthSlvPorts: AxiTileIdWidth,
      AxiIdUsedSlvPorts:  AxiTileIdWidth,
      UniqueIds:          1'b0,
      AxiAddrWidth:       AddrWidth,
      AxiDataWidth:       AxiDataWidth,
      NoAddrRules:        NumRules
    };

    axi_xbar #(
      .Cfg          (XbarCfg        ),
      .slv_aw_chan_t(axi_tile_aw_t  ),
      .mst_aw_chan_t(axi_tile_aw_t  ),
      .w_chan_t     (axi_tile_w_t   ),
      .slv_b_chan_t (axi_tile_b_t   ),
      .mst_b_chan_t (axi_tile_b_t   ),
      .slv_ar_chan_t(axi_tile_ar_t  ),
      .mst_ar_chan_t(axi_tile_ar_t  ),
      .slv_r_chan_t (axi_tile_r_t   ),
      .mst_r_chan_t (axi_tile_r_t   ),
      .slv_req_t    (axi_tile_req_t ),
      .slv_resp_t   (axi_tile_resp_t),
      .mst_req_t    (axi_tile_req_t ),
      .mst_resp_t   (axi_tile_resp_t),
      .rule_t       (xbar_rule_t    )
    ) i_dma_axi_xbar (
      .clk_i                (clk_i                        ),
      .rst_ni               (rst_ni                       ),
      .test_i               (1'b0                         ),
      .slv_ports_req_i      (axi_dma_premux_req           ),
      .slv_ports_resp_o     (axi_dma_premux_resp          ),
      .mst_ports_req_o      ({tcdm_req,axi_dma_req[d]}    ),
      .mst_ports_resp_i     ({tcdm_resp,axi_dma_resp[d]}  ),
      .addr_map_i           (addr_map                     ),
      .en_default_mst_port_i('1                           ),
      .default_mst_port_i   ('0                           )
    );

    reqrsp_req_t dma_reqrsp_req;
    reqrsp_rsp_t dma_reqrsp_rsp;
    reqrsp_req_t [NumTilesPerDma-1:0] dma_tile_req;
    reqrsp_rsp_t [NumTilesPerDma-1:0] dma_tile_rsp;

    axi_to_reqrsp #(
      .axi_req_t   (axi_tile_req_t ),
      .axi_rsp_t   (axi_tile_resp_t),
      .AddrWidth   (AddrWidth      ),
      .DataWidth   (AxiDataWidth   ),
      .IdWidth     (AxiTileIdWidth ),
      .BufDepth    (2              ),
      .reqrsp_req_t(reqrsp_req_t   ),
      .reqrsp_rsp_t(reqrsp_rsp_t   )
    ) i_axi_to_reqrsp (
      .clk_i       (clk_i         ),
      .rst_ni      (rst_ni        ),
      .busy_o      (/*unused*/    ),
      .axi_req_i   (tcdm_req      ),
      .axi_rsp_o   (tcdm_resp     ),
      .reqrsp_req_o(dma_reqrsp_req),
      .reqrsp_rsp_i(dma_reqrsp_rsp)
    );

    mempool_dma_tile_id_remapper i_mempool_group_tile_id_remapper (
      .dma_reqrsp_req_i (dma_reqrsp_req),
      .tile_id_remap_o  (tile_id_remap[d])
    );

    if (NumTilesPerDma > 1) begin: gen_dma_reqrsp_demux
      reqrsp_demux #(
        .NrPorts  (NumTilesPerDma        ),
        .req_t    (reqrsp_req_t          ),
        .rsp_t    (reqrsp_rsp_t          ),
        .RespDepth(2                     )
      ) i_reqrsp_demux (
          .clk_i       (clk_i            ),
          .rst_ni      (rst_ni           ),
          .slv_select_i(tile_id_remap[d] ),
          .slv_req_i   (dma_reqrsp_req   ),
          .slv_rsp_o   (dma_reqrsp_rsp   ),
          .mst_req_o   (dma_tile_req     ),
          .mst_rsp_i   (dma_tile_rsp     )
      );
    end else begin: gen_dma_reqrsp_bypass
      assign dma_tile_req = dma_reqrsp_req;
      assign dma_reqrsp_rsp = dma_tile_rsp;
    end

    // Assignment to TCDM interconnect
    // TODO: Reordering might be problematic
    for (genvar t = 0; unsigned'(t) < NumTilesPerDma; t++) begin: gen_dma_tile_connection
      assign tcdm_dma_req[d*NumTilesPerDma+t] = '{
                wdata: dma_tile_req[t].q.data,
                wen: dma_tile_req[t].q.write,
                be: dma_tile_req[t].q.strb,
                tgt_addr: {dma_tile_req[t].q.addr[ByteOffset + idx_width(NumBanksPerTile) + $clog2(NumTilesPerGroup) + $clog2(NumGroups)+:TCDMAddrMemWidth],
                          dma_tile_req[t].q.addr[ByteOffset+:idx_width(NumBanksPerTile)]}
              };
      assign tcdm_dma_req_valid[d*NumTilesPerDma+t]  = dma_tile_req[t].q_valid;
      assign dma_tile_rsp[t].q_ready = tcdm_dma_req_ready[d*NumTilesPerDma+t];
      assign dma_tile_rsp[t].p = '{
                data: tcdm_dma_resp[d*NumTilesPerDma+t].rdata,
                error: '0
              };
      assign dma_tile_rsp[t].p_valid = tcdm_dma_resp_valid[d*NumTilesPerDma+t];
      assign tcdm_dma_resp_ready[d*NumTilesPerDma+t] =dma_tile_req[t].p_ready;
    end
  end



  /**********************
   *  Group-level MSHR  *
   *********************/
  // Runtime configuration file. At MshrCfgRuntime=0 this has no storage and no write port: every
  // field const-folds to the elaborated default, so the build is bit-identical to the pre-CSR
  // design and the hold block still folds away on shapes that pin the window to 0.
  mempool_group_mshr_cfg #(
    .CfgRuntime               (MshrCfgRuntime         ),
    .DefHoldSubsSingle        (MshrDefHoldSubsSingle  ),
    .DefHoldSubsBurst         (MshrDefHoldSubsBurst   ),
    .DefHoldWindowSingle      (MshrDefHoldWindowSingle),
    .DefHoldWindowBurst       (MshrDefHoldWindowBurst ),
    .DefServeTimeout          (MshrDefServeTimeout    ),
    .DefBankShiftSingle       (MshrDefBankShiftSingle ),
    .DefBankShiftBurst        (MshrDefBankShiftBurst  ),
    .DefBankBurstBits         (MshrDefBankBurstBits   ),
    .DefCacheReuseTarget      (MshrDefCacheReuseTarget),
    .DefCacheTimeout          (MshrDefCacheTimeout    ),
    .DefBankfullBp            (MshrDefBankfullBp      ),
    // WIRE THE BOUND. Without this the module keeps its own default of 2047 and silently DROPS
    // every CSR write above it -- which is what made the 4095 campaign run at 2047 while looking
    // configured. The elaboration check at mshr_cfg.sv:122 only catches a width/bound mismatch,
    // not a bound that disagrees with the package.
    .HoldCntHwMax             (mempool_pkg::MshrCfgHoldCntMax),
    .MergeReqs                (MshrDefMergeReqs       ),
    // Same expression as mempool_group_mshr.sv:425. MaxBurstWords is a package constant, so the
    // two cannot drift; BurstAlignBits itself is a localparam inside the MSHR and not visible here.
    .BurstAlignBits           ((mempool_pkg::MaxBurstWords > 1)
                               ? $clog2(mempool_pkg::MaxBurstWords) : 1),
    .ServeTimeoutMustBeNonZero(MshrServeTimeoutNonZero)
  ) i_group_mshr_cfg (
    .clk_i       (clk_i            ),
    .rst_ni      (rst_ni           ),
    .wr_valid_i  (mshr_cfg_wr_valid),
    .wr_idx_i    (mshr_cfg_wr_idx  ),
    .wr_data_i   (mshr_cfg_wr_data ),
    .mshr_busy_i (mshr_busy        ),
    .cfg_o       (mshr_cfg         ),
    .status_o    (mshr_cfg_status  )
  );

  if (EnableGroupMshr) begin : gen_group_mshr
    mempool_group_mshr #(
      .NumGroups                (NumGroups                ),
      .NumTilesPerGroup         (NumTilesPerGroup         ),
      .NumRemoteReqPortsPerTile (NumRemoteReqPortsPerTile ),
      .NumRemoteRespPortsPerTile(NumRemoteRespPortsPerTile)
    ) i_group_mshr (
      .clk_i                    (clk_i                   ),
      .rst_ni                   (rst_ni                  ),
      .testmode_i               (testmode_i              ),
      .scan_enable_i            (scan_enable_i           ),
      .scan_data_i              (scan_data_i             ),
      .scan_data_o              (/* Unconnected */       ),
      .group_id_i               (group_id_i              ),
      .group_mshr_req_i         (group_mshr_req           ),
      .group_mshr_req_valid_i   (group_mshr_req_valid     ),
      .group_mshr_req_ready_o   (group_mshr_req_ready     ),
      .mshr_noc_req_o           (mshr_noc_req             ),
      .mshr_noc_req_valid_o     (mshr_noc_req_valid       ),
      .mshr_noc_req_ready_i     (mshr_noc_req_ready       ),
      .mshr_noc_resp_i          (mshr_noc_resp            ),
      .mshr_noc_resp_valid_i    (mshr_noc_resp_valid      ),
      .mshr_noc_resp_ready_o    (mshr_noc_resp_ready      ),
      .group_mshr_resp_o        (group_mshr_resp          ),
      .group_mshr_resp_valid_o  (group_mshr_resp_valid    ),
      .group_mshr_resp_ready_i  (group_mshr_resp_ready    ),
      .cfg_i                    (mshr_cfg                 ),
      .mshr_busy_o              (mshr_busy                )
    );
  end else begin : gen_group_mshr_bypass
    assign mshr_busy = 1'b0;
    assign mshr_noc_req        = group_mshr_req;
    assign mshr_noc_req_valid  = group_mshr_req_valid;
    assign group_mshr_req_ready = mshr_noc_req_ready;
    assign group_mshr_resp     = mshr_noc_resp;
    assign group_mshr_resp_valid = mshr_noc_resp_valid;
    assign mshr_noc_resp_ready = group_mshr_resp_ready;
  end

endmodule: mempool_group
