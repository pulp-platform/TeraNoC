// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "mempool/mempool.svh"

// One slice of the disaggregated group MSHR (mempool_pkg::MshrSplit).
//
// A slice reuses mempool_group_mshr over 4 lane-tiles (8 request / 8
// response lanes), plus the two lane folds that give it the 4-lane NoC face the backend wants:
//
//   tiles (4 x ports)  --8-->  [ fold 8->4 ]  --4-->  NoC       request side
//   tiles (4 x ports)  <--8--  [ steer 4->8 ] <--4--  NoC       response side
//
// The core MSHR is strictly lane-keyed (a bypass beat leaves on the lane it entered, a merged beat
// must arrive on its owner's lane), so the folds live here and the core stays symmetric.
//
// Request fold, per port class p and NoC lane k: round-robin between lane-local tiles {2k, 2k+1}.
// The slice's two bypass tiles have lane-local indices of equal parity ({0,2} or {1,3}, see
// mshr_bypass_slice), so they never share a NoC lane. The fold also stamps the header fields a
// NoC lane can no longer imply: src_tile_id (global tile) and the slice id above the tag.
//
// Response steer, per port class p and NoC lane k: a 1:2 demux on tile_id's low local bit. The
// group-level crossbar already put the beat on lane k = local[1] (mempool_group_floonoc_wrapper),
// so the demux completes the address. The slice id is stripped from the tag before the core sees it.
module mempool_group_mshr_slice
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
#(
  parameter int unsigned NumGroups                 = 16,
  parameter int unsigned NumTilesPerGroup          = 16,   // address geometry (the group's tiles)
  parameter int unsigned NumRemoteReqPortsPerTile  = 3,
  parameter int unsigned NumRemoteRespPortsPerTile = 3,
  parameter int unsigned SliceId                   = 0,    // 0..3 row R_k, 4..7 column C_k
  // Dependent, do not override.
  parameter int unsigned LaneTiles                 = MshrSliceTiles,   // 4
  parameter int unsigned NocLanes                  = LaneTiles / 2     // 2 per port class
) (
  input  logic                                                                                 clk_i,
  input  logic                                                                                 rst_ni,
  input  logic                                                                                 testmode_i,
  input  logic                                                                                 scan_enable_i,
  input  logic                                                                                 scan_data_i,
  output logic                                                                                 scan_data_o,
  input  logic                            [idx_width(NumGroups)-1:0]                           group_id_i,
  // Tiles -> slice (lane-local tile index)
  input  `STRUCT_VECT(tcdm_master_req_t,  [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1])       tile_req_i,
  input  logic                            [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1]        tile_req_valid_i,
  output logic                            [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1]        tile_req_ready_o,
  // Slice -> NoC
  output `STRUCT_VECT(tcdm_master_req_t,  [NocLanes-1:0][NumRemoteReqPortsPerTile-1:1])        noc_req_o,
  output logic                            [NocLanes-1:0][NumRemoteReqPortsPerTile-1:1]         noc_req_valid_o,
  input  logic                            [NocLanes-1:0][NumRemoteReqPortsPerTile-1:1]         noc_req_ready_i,
  // NoC -> slice
  input  `STRUCT_VECT(tcdm_master_resp_t, [NocLanes-1:0][NumRemoteRespPortsPerTile-1:1])       noc_resp_i,
  input  logic                            [NocLanes-1:0][NumRemoteRespPortsPerTile-1:1]        noc_resp_valid_i,
  output logic                            [NocLanes-1:0][NumRemoteRespPortsPerTile-1:1]        noc_resp_ready_o,
  // Slice -> tiles (lane-local tile index)
  output `STRUCT_VECT(tcdm_master_resp_t, [LaneTiles-1:0][NumRemoteRespPortsPerTile-1:1])      tile_resp_o,
  output logic                            [LaneTiles-1:0][NumRemoteRespPortsPerTile-1:1]       tile_resp_valid_o,
  input  logic                            [LaneTiles-1:0][NumRemoteRespPortsPerTile-1:1]       tile_resp_ready_i,
  // Runtime configuration, broadcast from the group's single CSR file.
  input  mshr_cfg_t                                                                            cfg_i,
  output logic                                                                                 mshr_busy_o
);

  // ---------------------------------------------------------------------------------------------
  // Elaboration checks
  // ---------------------------------------------------------------------------------------------
  initial begin
    if (!MshrSplit)
      $error("[mempool_group_mshr_slice] instantiated with GROUP_MSHR_SPLIT=0.");
    if (NumTilesPerGroup != 16)
      $error("[mempool_group_mshr_slice] the split MSHR requires 16 tiles per group (got %0d).",
             NumTilesPerGroup);
    if (LaneTiles != 4)
      $error("[mempool_group_mshr_slice] LaneTiles must be 4 (got %0d).", LaneTiles);
    if (SliceId >= MshrNumSlices)
      $error("[mempool_group_mshr_slice] SliceId %0d out of range.", SliceId);
  end

  localparam logic [MshrSliceIdW-1:0] Slice = MshrSliceIdW'(SliceId);

  // ---------------------------------------------------------------------------------------------
  // Core MSHR: 4 lane-tiles over the group's 16-tile address geometry
  // ---------------------------------------------------------------------------------------------
  tcdm_master_req_t  [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1]  core_noc_req;
  logic              [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1]  core_noc_req_valid;
  logic              [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1]  core_noc_req_ready;
  tcdm_master_resp_t [LaneTiles-1:0][NumRemoteRespPortsPerTile-1:1] core_noc_resp;
  logic              [LaneTiles-1:0][NumRemoteRespPortsPerTile-1:1] core_noc_resp_valid;
  logic              [LaneTiles-1:0][NumRemoteRespPortsPerTile-1:1] core_noc_resp_ready;

  mempool_group_mshr #(
    .NumGroups                (NumGroups                ),
    .NumTilesPerGroup         (LaneTiles                ),
    .NumAddrTiles             (NumTilesPerGroup         ),
    .SliceFamily              ((SliceId < 4) ? 1 : 2    ),
    .NumRemoteReqPortsPerTile (NumRemoteReqPortsPerTile ),
    .NumRemoteRespPortsPerTile(NumRemoteRespPortsPerTile)
  ) i_core (
    .clk_i                    (clk_i               ),
    .rst_ni                   (rst_ni              ),
    .testmode_i               (testmode_i          ),
    .scan_enable_i            (scan_enable_i       ),
    .scan_data_i              (scan_data_i         ),
    .scan_data_o              (scan_data_o         ),
    .group_id_i               (group_id_i          ),
    .group_mshr_req_i         (tile_req_i          ),
    .group_mshr_req_valid_i   (tile_req_valid_i    ),
    .group_mshr_req_ready_o   (tile_req_ready_o    ),
    .mshr_noc_req_o           (core_noc_req        ),
    .mshr_noc_req_valid_o     (core_noc_req_valid  ),
    .mshr_noc_req_ready_i     (core_noc_req_ready  ),
    .mshr_noc_resp_i          (core_noc_resp       ),
    .mshr_noc_resp_valid_i    (core_noc_resp_valid ),
    .mshr_noc_resp_ready_o    (core_noc_resp_ready ),
    .group_mshr_resp_o        (tile_resp_o         ),
    .group_mshr_resp_valid_o  (tile_resp_valid_o   ),
    .group_mshr_resp_ready_i  (tile_resp_ready_i   ),
    .cfg_i                    (cfg_i               ),
    .mshr_busy_o              (mshr_busy_o         )
  );

  // ---------------------------------------------------------------------------------------------
  // Request fold 8 -> 4: NoC lane (k, p) <- RR{ local tile 2k, local tile 2k+1 } on port p
  // ---------------------------------------------------------------------------------------------
  // Stamp the fields the fold destroys: the global source tile and the slice id in the tag.
  // The core stamps a lane-LOCAL tag (0 = bypass, 1..MshrNum+PoolNum = entry); the slice id goes
  // above it on EVERY request, so a bypass reads {slice, 0} and its response still returns here.
  tcdm_master_req_t [LaneTiles-1:0][NumRemoteReqPortsPerTile-1:1] core_noc_req_stamped;
  for (genvar l = 0; l < LaneTiles; l++) begin : gen_stamp_l
    for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_stamp_p
      always_comb begin
        core_noc_req_stamped[l][p]             = core_noc_req[l][p];
        core_noc_req_stamped[l][p].src_tile_id = tile_group_id_t'(mshr_slice_tile(Slice, 2'(l)));
        core_noc_req_stamped[l][p].mshr_tag    = {Slice, mshr_tag_local(core_noc_req[l][p].mshr_tag)};
      end
    end
  end

  for (genvar k = 0; k < NocLanes; k++) begin : gen_fold_k
    for (genvar p = 1; p < NumRemoteReqPortsPerTile; p++) begin : gen_fold_p
      rr_arb_tree #(
        .NumIn     (2                ),
        .DataType  (tcdm_master_req_t),
        .ExtPrio   (1'b0             ),
        .AxiVldRdy (1'b1             ),
        .LockIn    (1'b1             )
      ) i_req_fold (
        .clk_i   (clk_i                                                            ),
        .rst_ni  (rst_ni                                                           ),
        .flush_i (1'b0                                                             ),
        .rr_i    ('0                                                               ),
        .req_i   ({core_noc_req_valid[2*k+1][p],   core_noc_req_valid[2*k][p]}     ),
        .gnt_o   ({core_noc_req_ready[2*k+1][p],   core_noc_req_ready[2*k][p]}     ),
        .data_i  ({core_noc_req_stamped[2*k+1][p], core_noc_req_stamped[2*k][p]}   ),
        .req_o   (noc_req_valid_o[k][p]                                            ),
        .gnt_i   (noc_req_ready_i[k][p]                                            ),
        .data_o  (noc_req_o[k][p]                                                  ),
        .idx_o   (/* unused */                                                     )
      );
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Response steer 4 -> 8: NoC lane (k, p) -> local tile {2k, 2k+1} by tile_id's low local bit
  // ---------------------------------------------------------------------------------------------
  for (genvar k = 0; k < NocLanes; k++) begin : gen_steer_k
    for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_steer_p
      logic [1:0]        local_idx;
      tcdm_master_resp_t resp_local;
      logic [1:0]        demux_valid;
      logic [1:0]        demux_ready;

      assign local_idx = mshr_slice_local(Slice, 4'(noc_resp_i[k][p].tile_id));

      // Strip the slice id: the core compares the tag against its own MshrNum/PoolNum bounds.
      always_comb begin
        resp_local          = noc_resp_i[k][p];
        resp_local.mshr_tag = MshrTagWidth'(mshr_tag_local(noc_resp_i[k][p].mshr_tag));
      end

      stream_demux #(
        .N_OUP (2)
      ) i_resp_steer (
        .inp_valid_i (noc_resp_valid_i[k][p]),
        .inp_ready_o (noc_resp_ready_o[k][p]),
        .oup_sel_i   (local_idx[0]          ),
        .oup_valid_o (demux_valid           ),
        .oup_ready_i (demux_ready           )
      );

      for (genvar j = 0; j < 2; j++) begin : gen_steer_j
        assign core_noc_resp[2*k+j][p]       = resp_local;
        assign core_noc_resp_valid[2*k+j][p] = demux_valid[j];
        assign demux_ready[j]                = core_noc_resp_ready[2*k+j][p];
      end

`ifndef TARGET_SYNTHESIS
      // The group-level crossbar routes on {slice, local[1]}; a beat on lane k whose tile disagrees
      // was mis-routed upstream and would be delivered to the wrong tile.
      resp_lane_matches_tile: assert property (@(posedge clk_i) disable iff (!rst_ni)
          noc_resp_valid_i[k][p] |-> (local_idx[1] == k[0]))
        else $error("[mempool_group_mshr_slice] g=%0d slice=%0d lane=%0d port=%0d: response for tile %0d (local %0d) on the wrong NoC lane",
                    group_id_i, SliceId, k, p, noc_resp_i[k][p].tile_id, local_idx);
      resp_slice_matches_tag: assert property (@(posedge clk_i) disable iff (!rst_ni)
          noc_resp_valid_i[k][p] |->
            (mshr_resp_slice(noc_resp_i[k][p].mshr_tag) == Slice))
        else $error("[mempool_group_mshr_slice] g=%0d slice=%0d lane=%0d port=%0d: response tag 0x%0h for tile %0d belongs to another slice",
                    group_id_i, SliceId, k, p, noc_resp_i[k][p].mshr_tag, noc_resp_i[k][p].tile_id);
`endif
    end
  end

endmodule : mempool_group_mshr_slice
