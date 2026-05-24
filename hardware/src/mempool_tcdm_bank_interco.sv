// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "mempool/mempool.svh"

// Tile-internal TCDM bank-side interconnect: narrow req/resp crossbars, the
// wide DMA superbank demux/mux, per-bank wide-over-narrow priority, and the
// within-superbank bank-id remap. Replaces the legacy i_local_req_interco /
// i_local_resp_interco / i_dma_req_interco / i_dma_resp_interco stream_xbars,
// the per-superbank tcdm_wide_narrow_mux, and mempool_bank_id_remapper.sv.
//
// Bank-id remap is within-superbank only: only the low log2(NumBanksPerSB)
// bits of bank_id are rewritten (add the row-id slice). bank_id_hi (selects
// superbank for wide DMA) passes through unchanged so the wide chunk lands in
// the same superbank a narrow access of its base address would pick; the wide
// fork then rotates within that superbank to stay coherent with the narrow path.
//
// gen_superbank_resp_ini_addr (NumRemoteReqPortsPerTile vs
// NumRemoteRespPortsPerTile asymmetry) stays OUTSIDE this module: the caller
// passes the post-conditioning resp idx via mst_resp_ini_addr_i.

module mempool_tcdm_bank_interco
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
#(
  parameter int unsigned NumNarrowReq      = 8,
  parameter int unsigned NumNarrowResp     = 8,
  parameter int unsigned NumBanksPerTile   = 16,
  parameter int unsigned NumSuperbanks     = 1,
  parameter int unsigned NarrowDataWidth   = 32,
  parameter int unsigned WideDataWidth     = 512,
  parameter int unsigned ByteOffset        = 2,
  parameter bit          SpmBankIdRemap    = 0,
  parameter type narrow_req_t  = tcdm_slave_req_t,
  parameter type narrow_resp_t = tcdm_slave_resp_t,
  parameter type wide_req_t    = tcdm_dma_req_t,
  parameter type wide_resp_t   = tcdm_dma_resp_t,
  parameter type group_id_t    = mempool_pkg::group_id_t,
  // Must be wide enough to address NumNarrowResp ports (logic [idx_width(NumNarrowResp)-1:0]).
  parameter type resp_idx_t    = logic [3:0],
  // derived
  localparam int unsigned NumBanksPerSB    = NumBanksPerTile / NumSuperbanks,
  localparam int unsigned BankOffsetBits   = $clog2(NumBanksPerTile),
  localparam int unsigned BankIdLoBits     = $clog2(NumBanksPerSB),
  localparam int unsigned SBSelBits        = (NumSuperbanks > 1) ? $clog2(NumSuperbanks) : 1,
  localparam int unsigned NarrowBeWidth    = NarrowDataWidth / 8,
  localparam int unsigned RotBits          = (NumBanksPerSB > 1) ? $clog2(NumBanksPerSB) : 1,
  // Bank-id remap offset width (== bank_id_lo width). NumBanksPerSB >= 2 is
  // required (asserted below); a single-bank superbank would zero-width the slices.
  localparam int unsigned BankRemapShiftAmt = BankIdLoBits
) (
  input  logic                                          clk_i,
  input  logic                                          rst_ni,
  input  group_id_t                                     group_id_i,

  // ----- Narrow request inputs -----
  input  narrow_req_t  [NumNarrowReq-1:0]               slv_narrow_req_i,
  input  logic         [NumNarrowReq-1:0]               slv_narrow_req_valid_i,
  output logic         [NumNarrowReq-1:0]               slv_narrow_req_ready_o,

  // ----- Narrow response outputs -----
  output narrow_resp_t [NumNarrowResp-1:0]              slv_narrow_resp_o,
  output logic         [NumNarrowResp-1:0]              slv_narrow_resp_valid_o,
  input  logic         [NumNarrowResp-1:0]              slv_narrow_resp_ready_i,

  // ----- Wide DMA request input (single, demuxed internally) -----
  input  wide_req_t                                     slv_wide_req_i,
  input  logic                                          slv_wide_req_valid_i,
  output logic                                          slv_wide_req_ready_o,

  // ----- Wide DMA response output (single, muxed internally) -----
  output wide_resp_t                                    slv_wide_resp_o,
  output logic                                          slv_wide_resp_valid_o,
  input  logic                                          slv_wide_resp_ready_i,

  // ----- Bank-side request ports (per bank) -----
  output narrow_req_t  [NumBanksPerTile-1:0]            mst_req_o,
  output logic         [NumBanksPerTile-1:0]            mst_req_valid_o,
  input  logic         [NumBanksPerTile-1:0]            mst_req_ready_i,
  output logic         [NumBanksPerTile-1:0]            mst_req_wide_o,
  output resp_idx_t    [NumBanksPerTile-1:0]            mst_req_ini_addr_o,

  // ----- Bank-side response ports (per bank) -----
  input  narrow_resp_t [NumBanksPerTile-1:0]            mst_resp_i,
  input  logic         [NumBanksPerTile-1:0]            mst_resp_valid_i,
  output logic         [NumBanksPerTile-1:0]            mst_resp_ready_o,
  input  logic         [NumBanksPerTile-1:0]            mst_resp_wide_i,
  input  resp_idx_t    [NumBanksPerTile-1:0]            mst_resp_ini_addr_i
);

  // Rotation-FIFO depth. 2 is the floor of stream_fifo_optimal_wrap (it rejects
  // depth < 2 — a depth-2 FIFO is a spill register); raise it to pipeline more
  // outstanding wide reqs if a future bank ever holds more than one.
  localparam int unsigned RotFifoDepth = 2;

  // A single-bank superbank would zero-width the bank_id_lo slices.
  if (NumBanksPerSB < 2)
    $fatal(1, "mempool_tcdm_bank_interco: NumBanksPerSB (=%0d) must be >= 2.", NumBanksPerSB);

  // ============================================================
  // Narrow-request: bank-id-lo remap + xbar
  // ============================================================
  // Within-superbank constraint: only the low BankIdLoBits of bank_id are rewritten.
  logic [NumNarrowReq-1:0][BankOffsetBits-1:0] narrow_sel;
  for (genvar i = 0; i < NumNarrowReq; i++) begin : gen_narrow_sel
    logic [BankIdLoBits-1:0] raw_lo, new_lo;
    assign raw_lo = slv_narrow_req_i[i].tgt_addr[0 +: BankIdLoBits];
    if (SpmBankIdRemap) begin : gen_remap_active
      // Offset comes from the row-id slice just above bank_id.
      logic [BankRemapShiftAmt-1:0] offset_lo;
      assign offset_lo = slv_narrow_req_i[i].tgt_addr[BankOffsetBits +: BankRemapShiftAmt];
      assign new_lo = raw_lo + offset_lo;
    end else begin : gen_remap_passthrough
      assign new_lo = raw_lo;
    end
    if (NumSuperbanks > 1) begin : gen_hi_passthrough
      // bank_id_hi passes through untouched
      assign narrow_sel[i] =
          {slv_narrow_req_i[i].tgt_addr[BankIdLoBits +: (BankOffsetBits - BankIdLoBits)],
           new_lo};
    end else begin : gen_no_hi
      assign narrow_sel[i] = new_lo;
    end
  end

  narrow_req_t [NumBanksPerTile-1:0] narrow_to_bank;
  logic        [NumBanksPerTile-1:0] narrow_to_bank_valid;
  logic        [NumBanksPerTile-1:0] narrow_to_bank_ready;
  resp_idx_t   [NumBanksPerTile-1:0] narrow_to_bank_idx;

  stream_xbar #(
    .NumInp   (NumNarrowReq    ),
    .NumOut   (NumBanksPerTile ),
    .payload_t(narrow_req_t    )
  ) i_narrow_req_xbar (
    .clk_i  (clk_i                  ),
    .rst_ni (rst_ni                 ),
    .flush_i(1'b0                   ),
    .rr_i   ('0                     ),
    .data_i (slv_narrow_req_i       ),
    .valid_i(slv_narrow_req_valid_i ),
    .ready_o(slv_narrow_req_ready_o ),
    .sel_i  (narrow_sel             ),
    .data_o (narrow_to_bank         ),
    .valid_o(narrow_to_bank_valid   ),
    .ready_i(narrow_to_bank_ready   ),
    .idx_o  (narrow_to_bank_idx     )
  );

  // ============================================================
  // Wide DMA: demux single wide req to per-superbank streams.
  // ============================================================
  wide_req_t [NumSuperbanks-1:0] wide_to_sb;
  logic      [NumSuperbanks-1:0] wide_to_sb_valid;
  logic      [NumSuperbanks-1:0] wide_to_sb_ready;

  if (NumSuperbanks > 1) begin : gen_wide_req_demux
    stream_xbar #(
      .NumInp   (1            ),
      .NumOut   (NumSuperbanks),
      .payload_t(wide_req_t   )
    ) i_wide_req_demux (
      .clk_i  (clk_i               ),
      .rst_ni (rst_ni              ),
      .flush_i(1'b0                ),
      .rr_i   ('0                  ),
      .data_i (slv_wide_req_i      ),
      .valid_i(slv_wide_req_valid_i),
      .ready_o(slv_wide_req_ready_o),
      // Superbank select uses the upper bits of bank_id (unchanged by remap).
      .sel_i  (slv_wide_req_i.tgt_addr[BankIdLoBits +: SBSelBits]),
      .data_o (wide_to_sb          ),
      .valid_o(wide_to_sb_valid    ),
      .ready_i(wide_to_sb_ready    ),
      .idx_o  (/* unused */        )
    );
  end else begin : gen_wide_req_bypass
    assign wide_to_sb[0]        = slv_wide_req_i;
    assign wide_to_sb_valid[0]  = slv_wide_req_valid_i;
    assign slv_wide_req_ready_o = wide_to_sb_ready[0];
  end

  // ============================================================
  // Per-superbank wide handling: fork-with-rotation on the req side,
  // join-with-inverse-rotation on the resp side. Rotation amount per wide
  // req is queued in a per-superbank FIFO so outstanding reqs reassemble.
  // ============================================================
  wide_resp_t [NumSuperbanks-1:0] sb_wide_resp;
  logic       [NumSuperbanks-1:0] sb_wide_resp_valid;
  logic       [NumSuperbanks-1:0] sb_wide_resp_ready;

  // Per-bank wide req/resp signals coming out of the fork / into the join.
  logic        [NumBanksPerTile-1:0] wide_fork_valid;
  logic        [NumBanksPerTile-1:0] wide_fork_ready;
  narrow_req_t [NumBanksPerTile-1:0] wide_req_for_bank;
  logic        [NumBanksPerTile-1:0] wide_join_in_valid;
  logic        [NumBanksPerTile-1:0] wide_join_in_ready;

  for (genvar d = 0; d < NumSuperbanks; d++) begin : gen_sb
    // Rotation amount = (remapped) bank_id_lo of the wide req's tgt_addr.
    logic [RotBits-1:0] req_rot;
    if (NumBanksPerSB > 1) begin : gen_rot
      // Same bank-id-lo remap arithmetic as the narrow xbar sel, so rotations match.
      logic [BankIdLoBits-1:0] raw_lo, post_lo;
      assign raw_lo = wide_to_sb[d].tgt_addr[0 +: BankIdLoBits];
      if (SpmBankIdRemap) begin : gen_remap_on
        logic [BankRemapShiftAmt-1:0] off_lo;
        assign off_lo = wide_to_sb[d].tgt_addr[BankOffsetBits +: BankRemapShiftAmt];
        assign post_lo = raw_lo + off_lo;
      end else begin : gen_remap_off
        assign post_lo = raw_lo;
      end
      assign req_rot = post_lo;
    end else begin : gen_no_rot
      assign req_rot = '0;
    end

    // Capture each accepted wide req's rotation, replayed when its response joins
    // out. The fork only fires when the FIFO can enqueue (backpressure on accept),
    // so the FIFO can never overflow however many wide reqs a bank holds
    // outstanding; RotFifoDepth is the knob to pipeline more of them.
    logic [RotBits-1:0] resp_rot;
    logic               rot_fifo_in_valid,  rot_fifo_in_ready;
    logic               rot_fifo_out_valid, rot_fifo_out_ready;

    // Fork the wide req across the superbank's banks, gated on FIFO room.
    logic [NumBanksPerSB-1:0] sb_fork_valid;
    logic [NumBanksPerSB-1:0] sb_fork_ready;
    logic                     wide_acc_ready;
    stream_fork #(.N_OUP(NumBanksPerSB)) i_wide_fork (
      .clk_i  (clk_i                                   ),
      .rst_ni (rst_ni                                  ),
      .valid_i(wide_to_sb_valid[d] & rot_fifo_in_ready ),
      .ready_o(wide_acc_ready                          ),
      .valid_o(sb_fork_valid                           ),
      .ready_i(sb_fork_ready                           )
    );
    assign wide_to_sb_ready[d] = wide_acc_ready & rot_fifo_in_ready;
    // Enqueue when the banks accept; the FIFO masks the write itself when full, so
    // its input valid need not be gated by its input ready.
    assign rot_fifo_in_valid = wide_to_sb_valid[d] & wide_acc_ready;

    stream_fifo_optimal_wrap #(
      .Depth  (RotFifoDepth        ),
      .type_t (logic [RotBits-1:0] )
    ) i_rot_fifo (
      .clk_i      (clk_i             ),
      .rst_ni     (rst_ni            ),
      .flush_i    (1'b0              ),
      .testmode_i (1'b0              ),
      .usage_o    (/* unused */      ),
      .data_i     (req_rot           ),
      .valid_i    (rot_fifo_in_valid ),
      .ready_o    (rot_fifo_in_ready ),
      .data_o     (resp_rot          ),
      .valid_o    (rot_fifo_out_valid),
      .ready_i    (rot_fifo_out_ready)
    );

    // Compose each bank's wide req: rotated word slice + shared address.
    for (genvar b = 0; b < NumBanksPerSB; b++) begin : gen_sb_bank_req
      localparam int unsigned global_bank = d*NumBanksPerSB + b;
      always_comb begin
        // word j = (b - req_rot) mod NumBanksPerSB feeds bank port b.
        automatic int unsigned j = (b + NumBanksPerSB - req_rot) % NumBanksPerSB;
        wide_req_for_bank[global_bank] = '{
          wdata: '{
            meta_id: wide_to_sb[d].wdata.meta_id,
            core_id: wide_to_sb[d].wdata.core_id,
            amo:     wide_to_sb[d].wdata.amo,
            data:    wide_to_sb[d].wdata.data[j*NarrowDataWidth +: NarrowDataWidth]
          },
          wen:           wide_to_sb[d].wen,
          be:            wide_to_sb[d].be[j*NarrowBeWidth +: NarrowBeWidth],
          tgt_addr:      wide_to_sb[d].tgt_addr,
          ini_addr:      '0,
          src_group_id:  group_id_i
        };
      end
      assign wide_fork_valid[global_bank] = sb_fork_valid[b];
      assign sb_fork_ready[b]             = wide_fork_ready[global_bank];
    end

    // Wide resp join across the superbank's banks; inverse rotation uses
    // resp_rot from the FIFO head.
    logic [NumBanksPerSB-1:0] sb_join_valid;
    logic [NumBanksPerSB-1:0] sb_join_ready;
    stream_join #(.N_INP(NumBanksPerSB)) i_wide_join (
      .inp_valid_i(sb_join_valid          ),
      .inp_ready_o(sb_join_ready          ),
      .oup_valid_o(sb_wide_resp_valid[d]  ),
      .oup_ready_i(sb_wide_resp_ready[d]  )
    );
    assign rot_fifo_out_ready = sb_wide_resp_valid[d] & sb_wide_resp_ready[d];
    // The rotation must be queued before its response joins out; consuming it from
    // an empty FIFO would replay a stale rotation and corrupt the reassembled rdata.
`ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        rot_fifo_out_ready |-> rot_fifo_out_valid)
      else $fatal(1, "[mempool_tcdm_bank_interco] sb=%0d rotation FIFO drained while empty", d);
`endif

    // Wire the per-bank wide-side response handshake into the join.
    for (genvar b = 0; b < NumBanksPerSB; b++) begin : gen_sb_bank_resp
      localparam int unsigned global_bank = d*NumBanksPerSB + b;
      assign sb_join_valid[b]                  = wide_join_in_valid[global_bank];
      assign wide_join_in_ready[global_bank]   = sb_join_ready[b];
    end

    // Reassemble wide rdata with inverse rotation, then carry metadata.
    always_comb begin
      sb_wide_resp[d] = '{rdata: '{default: '0}};
      for (int b = 0; b < NumBanksPerSB; b++) begin
        // Bank port b carries word j = (b - resp_rot) mod NumBanksPerSB.
        automatic int unsigned j = (b + NumBanksPerSB - resp_rot) % NumBanksPerSB;
        sb_wide_resp[d].rdata.data[j*NarrowDataWidth +: NarrowDataWidth]
            = mst_resp_i[d*NumBanksPerSB + b].rdata.data;
      end
      // Metadata from the lowest bank — all banks of a wide chunk share it.
      sb_wide_resp[d].rdata.meta_id = mst_resp_i[d*NumBanksPerSB].rdata.meta_id;
      sb_wide_resp[d].rdata.core_id = mst_resp_i[d*NumBanksPerSB].rdata.core_id;
      sb_wide_resp[d].rdata.amo     = mst_resp_i[d*NumBanksPerSB].rdata.amo;
    end
  end

  // ============================================================
  // Per-bank priority: wide overrides narrow at the request port.
  // ============================================================
  for (genvar b = 0; b < NumBanksPerTile; b++) begin : gen_bank_mux
    always_comb begin
      if (wide_fork_valid[b]) begin
        mst_req_o[b]              = wide_req_for_bank[b];
        mst_req_valid_o[b]        = wide_fork_valid[b];
        mst_req_wide_o[b]         = 1'b1;
        wide_fork_ready[b]        = mst_req_ready_i[b];
        narrow_to_bank_ready[b]   = 1'b0;
        mst_req_ini_addr_o[b]     = '0;
      end else begin
        mst_req_o[b]              = narrow_to_bank[b];
        mst_req_valid_o[b]        = narrow_to_bank_valid[b];
        mst_req_wide_o[b]         = 1'b0;
        wide_fork_ready[b]        = 1'b0;
        narrow_to_bank_ready[b]   = mst_req_ready_i[b];
        mst_req_ini_addr_o[b]     = narrow_to_bank_idx[b];
      end
    end
  end

  // ============================================================
  // Per-bank response split: wide → join, narrow → resp xbar.
  // ============================================================
  narrow_resp_t [NumBanksPerTile-1:0] narrow_resp_to_xbar;
  logic         [NumBanksPerTile-1:0] narrow_resp_to_xbar_valid;
  logic         [NumBanksPerTile-1:0] narrow_resp_to_xbar_ready;

  for (genvar b = 0; b < NumBanksPerTile; b++) begin : gen_resp_split
    assign narrow_resp_to_xbar[b] = mst_resp_i[b];
    always_comb begin
      if (mst_resp_wide_i[b]) begin
        wide_join_in_valid[b]        = mst_resp_valid_i[b];
        mst_resp_ready_o[b]          = wide_join_in_ready[b];
        narrow_resp_to_xbar_valid[b] = 1'b0;
      end else begin
        wide_join_in_valid[b]        = 1'b0;
        mst_resp_ready_o[b]          = narrow_resp_to_xbar_ready[b];
        narrow_resp_to_xbar_valid[b] = mst_resp_valid_i[b];
      end
    end
  end

  // ============================================================
  // Narrow response xbar (NumBanksPerTile → NumNarrowResp).
  // sel = caller-supplied resp idx (already conditioned for any
  // NumRemoteReqPortsPerTile vs NumRemoteRespPortsPerTile asymmetry).
  // ============================================================
  stream_xbar #(
    .NumInp   (NumBanksPerTile ),
    .NumOut   (NumNarrowResp   ),
    .payload_t(narrow_resp_t   )
  ) i_narrow_resp_xbar (
    .clk_i  (clk_i                      ),
    .rst_ni (rst_ni                     ),
    .flush_i(1'b0                       ),
    .rr_i   ('0                         ),
    .data_i (narrow_resp_to_xbar        ),
    .valid_i(narrow_resp_to_xbar_valid  ),
    .ready_o(narrow_resp_to_xbar_ready  ),
    .sel_i  (mst_resp_ini_addr_i        ),
    .data_o (slv_narrow_resp_o          ),
    .valid_o(slv_narrow_resp_valid_o    ),
    .ready_i(slv_narrow_resp_ready_i    ),
    .idx_o  (/* unused */               )
  );

  // ============================================================
  // Wide response mux (NumSuperbanks → 1).
  // ============================================================
  if (NumSuperbanks > 1) begin : gen_wide_resp_mux
    stream_xbar #(
      .NumInp   (NumSuperbanks ),
      .NumOut   (1             ),
      .payload_t(wide_resp_t   )
    ) i_wide_resp_mux (
      .clk_i  (clk_i                 ),
      .rst_ni (rst_ni                ),
      .flush_i(1'b0                  ),
      .rr_i   ('0                    ),
      .data_i (sb_wide_resp          ),
      .valid_i(sb_wide_resp_valid    ),
      .ready_o(sb_wide_resp_ready    ),
      .sel_i  ('0                    ),
      .data_o (slv_wide_resp_o       ),
      .valid_o(slv_wide_resp_valid_o ),
      .ready_i(slv_wide_resp_ready_i ),
      .idx_o  (/* unused */          )
    );
  end else begin : gen_wide_resp_bypass
    assign slv_wide_resp_o        = sb_wide_resp[0];
    assign slv_wide_resp_valid_o  = sb_wide_resp_valid[0];
    assign sb_wide_resp_ready[0]  = slv_wide_resp_ready_i;
  end

endmodule
