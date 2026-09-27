// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Samuel Riedel <sriedel@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

// This module multiplexes many narrow ports and one wide port onto many narrow
// ports. The wide port is prioritized.
//
// Posted wide writes (PostedWrites). A wide write needs no data back, only an
// acknowledgement, yet a bank (tcdm_adapter) takes a request only when its response
// queue is empty, so one bank still holding a narrow read response it cannot deliver
// stalls the whole wide beat. With PostedWrites a wide write is sent to the banks as
// POSTED (mst_req_posted_o): each bank takes it whenever its SRAM port is free and
// returns nothing, and the acknowledgement is generated here once every bank has
// taken its word. Responses on the wide port stay in request order:
//   * a wide write is posted only while no bank-routed wide response is outstanding,
//     so an acknowledgement never overtakes an older wide read or non-posted write;
//   * a bank-routed wide response is released only once every older acknowledgement
//     has left;
//   * the decision is taken when the wide request first appears and held until all
//     banks have taken it, so the banks of one beat always agree.
// A write that cannot be posted (a bank-routed response outstanding, or the
// acknowledgement counter full) takes the bank path as before.
module tcdm_wide_narrow_mux #(
  // Width of narrow data.
  parameter int unsigned NarrowDataWidth = 0,
  // Width of wide data.
  parameter int unsigned WideDataWidth   = 0,
  // Request type of narrow inputs.
  parameter type narrow_req_t        = logic,
  // Response type of narrow inputs.
  parameter type narrow_rsp_t        = logic,
  // Request type of wide inputs.
  parameter type wide_req_t          = logic,
  // Response type of wide inputs.
  parameter type wide_rsp_t          = logic,
  // Group ID type, FlooNoC Added
  parameter type group_id_t          = logic,
  // Send wide writes to the banks as posted writes (see above).
  parameter bit          PostedWrites    = 1'b0,
  // Derived. *Do not override*
  // Number of narrow inputs.
  parameter int unsigned NrPorts = WideDataWidth / NarrowDataWidth
) (
  input  logic                          clk_i,
  input  logic                          rst_ni,
  // Group ID, FlooNoC Added
  input  group_id_t                     group_id_i,
  // Narrow inputs
  input  narrow_req_t [NrPorts-1:0] slv_narrow_req_i,
  input  logic        [NrPorts-1:0] slv_narrow_req_valid_i,
  output logic        [NrPorts-1:0] slv_narrow_req_ready_o,
  output narrow_rsp_t [NrPorts-1:0] slv_narrow_rsp_o,
  output logic        [NrPorts-1:0] slv_narrow_rsp_valid_o,
  input  logic        [NrPorts-1:0] slv_narrow_rsp_ready_i,
  // Wide input
  input  wide_req_t                 slv_wide_req_i,
  input  logic                      slv_wide_req_valid_i,
  output logic                      slv_wide_req_ready_o,
  output wide_rsp_t                 slv_wide_rsp_o,
  output logic                      slv_wide_rsp_valid_o,
  input  logic                      slv_wide_rsp_ready_i,
  // Multiplexed outputs
  output narrow_req_t [NrPorts-1:0] mst_req_o,
  output logic        [NrPorts-1:0] mst_req_wide_o,
  output logic        [NrPorts-1:0] mst_req_posted_o,
  output logic        [NrPorts-1:0] mst_req_valid_o,
  input  logic        [NrPorts-1:0] mst_req_ready_i,
  input  narrow_rsp_t [NrPorts-1:0] mst_rsp_i,
  input  logic        [NrPorts-1:0] mst_rsp_wide_i,
  input  logic        [NrPorts-1:0] mst_rsp_valid_i,
  output logic        [NrPorts-1:0] mst_rsp_ready_o
);

  localparam int unsigned NarrowBeWidth = NarrowDataWidth/8;

  // Posted-write state (tied off without PostedWrites). Declared here, not in the
  // generate below, so waveforms and assertions can name them.
  localparam int unsigned CntWidth = 3;
  localparam logic [CntWidth-1:0] CntMax = '1;
  logic                wide_posted;          // the current wide request goes posted
  logic                fork_open_q;          // a wide request is partly taken by the banks
  logic                posted_q;             // ... and the decision it was started with
  logic [CntWidth-1:0] ack_cnt_q;            // acknowledgements owed for posted writes
  logic [CntWidth-1:0] bank_out_q;           // wide requests owed a bank-routed response
  logic                wide_hsk;             // wide request fully taken
  logic                join_valid, join_ready;
  logic                ack_pop, bank_rsp_pop;

  // Request path
  logic [NrPorts-1:0] forked_wide_req_valid;
  logic [NrPorts-1:0] forked_wide_req_ready;

  // Fork the wide request into multiple narrow ones
  stream_fork #(
    .N_OUP (NrPorts)
  ) i_wide_stream_fork (
    .clk_i  (clk_i                ),
    .rst_ni (rst_ni               ),
    .valid_i(slv_wide_req_valid_i ),
    .ready_o(slv_wide_req_ready_o ),
    .valid_o(forked_wide_req_valid),
    .ready_i(forked_wide_req_ready)
  );

  always_comb begin
    // Feed-through narrow ports by default
    mst_req_valid_o = slv_narrow_req_valid_i;
    slv_narrow_req_ready_o = mst_req_ready_i;
    mst_req_wide_o = '0;
    mst_req_posted_o = '0;
    mst_req_o = slv_narrow_req_i;
    // Block wide by default
    forked_wide_req_ready = '0;

    for (int i = 0; i < NrPorts; i++) begin
      if (forked_wide_req_valid[i]) begin
        // Select the wide port
        mst_req_valid_o[i] = forked_wide_req_valid[i];
        forked_wide_req_ready[i] = mst_req_ready_i[i];
        mst_req_wide_o[i] = 1'b1;
        mst_req_posted_o[i] = wide_posted;
        mst_req_o[i] = '{
          wdata: slv_wide_req_i.wdata[i*NarrowDataWidth+:NarrowDataWidth],
          wen: slv_wide_req_i.wen,
          be: slv_wide_req_i.be[i*NarrowBeWidth+:NarrowBeWidth],
          tgt_addr: slv_wide_req_i.tgt_addr,
          ini_addr: '0,
          src_group_id: group_id_i, // FlooNoC Added
          burst_len: '0,
          mshr_tag: '0 // Tier-b: DMA/wide path does not use the MSHR tag
        };
        // Block access from narrow ports.
        slv_narrow_req_ready_o[i] = 1'b0;
      end
    end
  end

  // Response path
  logic [NrPorts-1:0] forked_wide_rsp_valid;
  logic [NrPorts-1:0] forked_wide_rsp_ready;

  // Join the multiple narrow requests into one wide one
  stream_join #(
    .N_INP (NrPorts)
  ) i_wide_stream_join (
    .inp_valid_i(forked_wide_rsp_valid),
    .inp_ready_o(forked_wide_rsp_ready),
    .oup_valid_o(join_valid           ),
    .oup_ready_i(join_ready           )
  );

  assign wide_hsk     = slv_wide_req_valid_i && slv_wide_req_ready_o;
  assign bank_rsp_pop = join_valid && join_ready;

  if (PostedWrites) begin : gen_posted
    logic posted_new;
    // Post only with no bank-routed response outstanding (order) and room to count the
    // acknowledgement. Both counters can only fall while a request is partly taken, so
    // the decision held in posted_q stays legal until the request completes.
    assign posted_new  = slv_wide_req_i.wen && (bank_out_q == '0) && (ack_cnt_q != CntMax);
    assign wide_posted = fork_open_q ? posted_q : posted_new;

    // Acknowledgements are older than any bank-routed response still to come, so they
    // leave first; the response data is irrelevant for a write.
    assign ack_pop              = (ack_cnt_q != '0) && slv_wide_rsp_ready_i;
    assign slv_wide_rsp_valid_o = (ack_cnt_q != '0) || join_valid;
    assign join_ready           = slv_wide_rsp_ready_i && (ack_cnt_q == '0);

    `FF(fork_open_q, slv_wide_req_valid_i && !slv_wide_req_ready_o, 1'b0, clk_i, rst_ni)
    `FF(posted_q, wide_posted, 1'b0, clk_i, rst_ni)
    `FF(ack_cnt_q, ack_cnt_q + CntWidth'(wide_hsk && wide_posted) - CntWidth'(ack_pop),
        '0, clk_i, rst_ni)
    `FF(bank_out_q, bank_out_q + CntWidth'(wide_hsk && !wide_posted) - CntWidth'(bank_rsp_pop),
        '0, clk_i, rst_ni)
  end else begin : gen_no_posted
    assign wide_posted          = 1'b0;
    assign fork_open_q          = 1'b0;
    assign posted_q             = 1'b0;
    assign ack_cnt_q            = '0;
    assign bank_out_q           = '0;
    assign ack_pop              = 1'b0;
    assign slv_wide_rsp_valid_o = join_valid;
    assign join_ready           = slv_wide_rsp_ready_i;
  end

  always_comb begin
    // Broadcast data
    slv_narrow_rsp_o = mst_rsp_i;
    // Tie off both interfaces by default
    slv_narrow_rsp_valid_o = '0;
    forked_wide_rsp_valid = '0;
    mst_rsp_ready_o = '0;
    for (int i = 0; i < NrPorts; i++) begin
      // Broadcast data from all banks.
      slv_wide_rsp_o.rdata[i*NarrowDataWidth+:NarrowDataWidth] = mst_rsp_i[i].rdata;
      // Connect handshake based on selection
      if (mst_rsp_wide_i[i]) begin
        forked_wide_rsp_valid[i] = mst_rsp_valid_i[i];
        mst_rsp_ready_o[i] = forked_wide_rsp_ready[i];
      end else begin
        slv_narrow_rsp_valid_o[i] = mst_rsp_valid_i[i];
        mst_rsp_ready_o[i] = slv_narrow_rsp_ready_i[i];
      end
    end
  end

  // Check parameters
  if (NrPorts*NarrowDataWidth != WideDataWidth) begin
    $error("[tcdm_wide_narrow_mux] WideDataWidth must be divisible by NarrowDataWidth.");
  end

`ifndef TARGET_SYNTHESIS
`ifndef VERILATOR
  if (PostedWrites) begin : gen_posted_asserts
    // Only a write may go posted: a load needs its data from the banks.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     (slv_wide_req_valid_i && wide_posted) |-> slv_wide_req_i.wen)
      else $fatal(1, "[tcdm_wide_narrow_mux] posted wide request is not a write");
    // A posted write never waits on the ack counter it would overflow.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     (wide_hsk && wide_posted) |-> (ack_cnt_q != CntMax || ack_pop))
      else $fatal(1, "[tcdm_wide_narrow_mux] posted-write acknowledgement counter overflow");
    // Every bank-routed wide response was counted: a posted write never returns one.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     bank_rsp_pop |-> (bank_out_q != '0))
      else $fatal(1, "[tcdm_wide_narrow_mux] wide response from the banks with none owed");
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     (wide_hsk && !wide_posted) |-> (bank_out_q != CntMax || bank_rsp_pop))
      else $fatal(1, "[tcdm_wide_narrow_mux] bank-routed wide response counter overflow");
    // Order: no bank-routed wide response leaves while an older acknowledgement waits.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
                     bank_rsp_pop |-> (ack_cnt_q == '0))
      else $fatal(1, "[tcdm_wide_narrow_mux] wide response overtook a posted acknowledgement");
  end
`endif
`endif
endmodule
