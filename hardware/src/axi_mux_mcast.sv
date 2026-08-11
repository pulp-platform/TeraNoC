// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// axi_mux_mcast -- project-local variant of hardware/deps/axi/src/axi_mux.sv that can deliver ONE
// R beat to SEVERAL slave ports in the same cycle (R-MCAST, docs/icache_rmcast_design.md).
//
// WHY A COPY: the upstream axi_mux has ~8 instantiation sites (including every tile), so it is not
// edited in place. Only the R-channel block differs from upstream; everything else is verbatim.
// With RMcastEn = 0 the multicast logic is NOT generated and this module is bit-identical to
// axi_mux, so it is safe to instantiate unconditionally.
//
// Regenerate after an upstream axi_mux bump: see docs/icache_rmcast_design.md 6.1.

// Copyright (c) 2019 ETH Zurich, University of Bologna
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Authors:
// - Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
// - Andreas Kurth <akurth@iis.ee.ethz.ch>

// AXI Multiplexer: This module multiplexes the AXI4 slave ports down to one master port.
// The AXI IDs from the slave ports get extended with the respective slave port index.
// The extension width can be calculated with `$clog2(NoSlvPorts)`. This means the AXI
// ID for the master port has to be this `$clog2(NoSlvPorts)` wider than the ID for the
// slave ports.
// Responses are switched based on these bits. For example, with 4 slave ports
// a response with ID `6'b100110` will be forwarded to slave port 2 (`2'b10`).

// register macros
`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

module axi_mux_mcast #(
  // AXI parameter and channel types
  parameter int unsigned SlvAxiIDWidth = 32'd0, // AXI ID width, slave ports
  parameter type         slv_aw_chan_t = logic, // AW Channel Type, slave ports
  parameter type         mst_aw_chan_t = logic, // AW Channel Type, master port
  parameter type         w_chan_t      = logic, //  W Channel Type, all ports
  parameter type         slv_b_chan_t  = logic, //  B Channel Type, slave ports
  parameter type         mst_b_chan_t  = logic, //  B Channel Type, master port
  parameter type         slv_ar_chan_t = logic, // AR Channel Type, slave ports
  parameter type         mst_ar_chan_t = logic, // AR Channel Type, master port
  parameter type         slv_r_chan_t  = logic, //  R Channel Type, slave ports
  parameter type         mst_r_chan_t  = logic, //  R Channel Type, master port
  parameter type         slv_req_t     = logic, // Slave port request type
  parameter type         slv_resp_t    = logic, // Slave port response type
  parameter type         mst_req_t     = logic, // Master ports request type
  parameter type         mst_resp_t    = logic, // Master ports response type
  parameter int unsigned NoSlvPorts    = 32'd0, // Number of slave ports
  // Maximum number of outstanding transactions per write
  parameter int unsigned MaxWTrans     = 32'd8,
  // If enabled, this multiplexer is purely combinatorial
  parameter bit          FallThrough   = 1'b0,
  // add spill register on write master ports, adds a cycle latency on write channels
  parameter bit          SpillAw       = 1'b1,
  parameter bit          SpillW        = 1'b0,
  parameter bit          SpillB        = 1'b0,
  // add spill register on read master ports, adds a cycle latency on read channels
  parameter bit          SpillAr       = 1'b1,
  parameter bit          SpillR        = 1'b0,
  // R-MCAST: when 0 this module is BIT-IDENTICAL to axi_mux (the multicast logic is not generated
  // at all and mst_r_mcast_mask_i is unused). See docs/icache_rmcast_design.md.
  parameter bit          RMcastEn      = 1'b0
) (
  input  logic                       clk_i,    // Clock
  input  logic                       rst_ni,   // Asynchronous reset active low
  input  logic                       test_i,   // Test Mode enable
  // slave ports (AXI inputs), connect master modules here
  input  slv_req_t  [NoSlvPorts-1:0] slv_reqs_i,
  output slv_resp_t [NoSlvPorts-1:0] slv_resps_o,
  // master port (AXI outputs), connect slave modules here
  output mst_req_t                   mst_req_o,
  input  mst_resp_t                  mst_resp_i,
  // N-hot "deliver this R beat to these slave ports" mask, valid with mst_resp_i.r_valid.
  // All-zero => behave exactly like axi_mux (single target decoded from r.id).
  input  logic      [NoSlvPorts-1:0] mst_r_mcast_mask_i
);

  localparam int unsigned MstIdxBits    = $clog2(NoSlvPorts);
  localparam int unsigned MstAxiIDWidth = SlvAxiIDWidth + MstIdxBits;

  // pass through if only one slave port
  if (NoSlvPorts == 32'h1) begin : gen_no_mux
    spill_register #(
      .T       ( mst_aw_chan_t ),
      .Bypass  ( ~SpillAw      )
    ) i_aw_spill_reg (
      .clk_i   ( clk_i                    ),
      .rst_ni  ( rst_ni                   ),
      .valid_i ( slv_reqs_i[0].aw_valid   ),
      .ready_o ( slv_resps_o[0].aw_ready  ),
      .data_i  ( slv_reqs_i[0].aw         ),
      .valid_o ( mst_req_o.aw_valid       ),
      .ready_i ( mst_resp_i.aw_ready      ),
      .data_o  ( mst_req_o.aw             )
    );
    spill_register #(
      .T       ( w_chan_t ),
      .Bypass  ( ~SpillW  )
    ) i_w_spill_reg (
      .clk_i   ( clk_i                   ),
      .rst_ni  ( rst_ni                  ),
      .valid_i ( slv_reqs_i[0].w_valid   ),
      .ready_o ( slv_resps_o[0].w_ready  ),
      .data_i  ( slv_reqs_i[0].w         ),
      .valid_o ( mst_req_o.w_valid       ),
      .ready_i ( mst_resp_i.w_ready      ),
      .data_o  ( mst_req_o.w             )
    );
    spill_register #(
      .T       ( mst_b_chan_t ),
      .Bypass  ( ~SpillB      )
    ) i_b_spill_reg (
      .clk_i   ( clk_i                  ),
      .rst_ni  ( rst_ni                 ),
      .valid_i ( mst_resp_i.b_valid     ),
      .ready_o ( mst_req_o.b_ready      ),
      .data_i  ( mst_resp_i.b           ),
      .valid_o ( slv_resps_o[0].b_valid ),
      .ready_i ( slv_reqs_i[0].b_ready  ),
      .data_o  ( slv_resps_o[0].b       )
    );
    spill_register #(
      .T       ( mst_ar_chan_t ),
      .Bypass  ( ~SpillAr      )
    ) i_ar_spill_reg (
      .clk_i   ( clk_i                    ),
      .rst_ni  ( rst_ni                   ),
      .valid_i ( slv_reqs_i[0].ar_valid   ),
      .ready_o ( slv_resps_o[0].ar_ready  ),
      .data_i  ( slv_reqs_i[0].ar         ),
      .valid_o ( mst_req_o.ar_valid       ),
      .ready_i ( mst_resp_i.ar_ready      ),
      .data_o  ( mst_req_o.ar             )
    );
    spill_register #(
      .T       ( mst_r_chan_t ),
      .Bypass  ( ~SpillR      )
    ) i_r_spill_reg (
      .clk_i   ( clk_i                  ),
      .rst_ni  ( rst_ni                 ),
      .valid_i ( mst_resp_i.r_valid     ),
      .ready_o ( mst_req_o.r_ready      ),
      .data_i  ( mst_resp_i.r           ),
      .valid_o ( slv_resps_o[0].r_valid ),
      .ready_i ( slv_reqs_i[0].r_ready  ),
      .data_o  ( slv_resps_o[0].r       )
    );
// Validate parameters.
// pragma translate_off
    `ASSERT_INIT(CorrectIdWidthSlvAw, $bits(slv_reqs_i[0].aw.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthSlvB, $bits(slv_resps_o[0].b.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthSlvAr, $bits(slv_reqs_i[0].ar.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthSlvR, $bits(slv_resps_o[0].r.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthMstAw, $bits(mst_req_o.aw.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthMstB, $bits(mst_resp_i.b.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthMstAr, $bits(mst_req_o.ar.id) == SlvAxiIDWidth)
    `ASSERT_INIT(CorrectIdWidthMstR, $bits(mst_resp_i.r.id) == SlvAxiIDWidth)
// pragma translate_on

  // other non degenerate cases
  end else begin : gen_mux

    typedef logic [MstIdxBits-1:0] switch_id_t;

    // AXI channels between the ID prepend unit and the rest of the multiplexer
    mst_aw_chan_t [NoSlvPorts-1:0] slv_aw_chans;
    logic         [NoSlvPorts-1:0] slv_aw_valids, slv_aw_readies;
    w_chan_t      [NoSlvPorts-1:0] slv_w_chans;
    logic         [NoSlvPorts-1:0] slv_w_valids,  slv_w_readies;
    mst_b_chan_t  [NoSlvPorts-1:0] slv_b_chans;
    logic         [NoSlvPorts-1:0] slv_b_valids,  slv_b_readies;
    mst_ar_chan_t [NoSlvPorts-1:0] slv_ar_chans;
    logic         [NoSlvPorts-1:0] slv_ar_valids, slv_ar_readies;
    mst_r_chan_t  [NoSlvPorts-1:0] slv_r_chans;
    logic         [NoSlvPorts-1:0] slv_r_valids,  slv_r_readies;

    // These signals are all ID prepended
    // AW channel
    mst_aw_chan_t   mst_aw_chan;
    logic           mst_aw_valid, mst_aw_ready;

    // AW master handshake internal, so that we are able to stall, if w_fifo is full
    logic           aw_valid,     aw_ready;

    // FF to lock the AW valid signal, when a new arbitration decision is made the decision
    // gets pushed into the W FIFO, when it now stalls prevent subsequent pushing
    // This FF removes AW to W dependency
    logic           lock_aw_valid_d, lock_aw_valid_q;
    logic           load_aw_lock;

    // signals for the FIFO that holds the last switching decision of the AW channel
    logic           w_fifo_full,  w_fifo_empty;
    logic           w_fifo_push,  w_fifo_pop;
    switch_id_t     w_fifo_data;

    // W channel spill reg
    w_chan_t        mst_w_chan;
    logic           mst_w_valid,  mst_w_ready;

    // master ID in the b_id
    switch_id_t     switch_b_id;

    // B channel spill reg
    mst_b_chan_t    mst_b_chan;
    logic           mst_b_valid;

    // AR channel for when spill is enabled
    mst_ar_chan_t   mst_ar_chan;
    logic           ar_valid,     ar_ready;

    // master ID in the r_id
    switch_id_t     switch_r_id;

    // R channel spill reg
    mst_r_chan_t    mst_r_chan;
    logic           mst_r_valid;

    //--------------------------------------
    // ID prepend for all slave ports
    //--------------------------------------
    for (genvar i = 0; i < NoSlvPorts; i++) begin : gen_id_prepend
      axi_id_prepend #(
        .NoBus            ( 32'd1               ), // one AXI bus per slave port
        .AxiIdWidthSlvPort( SlvAxiIDWidth       ),
        .AxiIdWidthMstPort( MstAxiIDWidth       ),
        .slv_aw_chan_t    ( slv_aw_chan_t       ),
        .slv_w_chan_t     ( w_chan_t            ),
        .slv_b_chan_t     ( slv_b_chan_t        ),
        .slv_ar_chan_t    ( slv_ar_chan_t       ),
        .slv_r_chan_t     ( slv_r_chan_t        ),
        .mst_aw_chan_t    ( mst_aw_chan_t       ),
        .mst_w_chan_t     ( w_chan_t            ),
        .mst_b_chan_t     ( mst_b_chan_t        ),
        .mst_ar_chan_t    ( mst_ar_chan_t       ),
        .mst_r_chan_t     ( mst_r_chan_t        )
      ) i_id_prepend (
        .pre_id_i         ( switch_id_t'(i)         ),
        .slv_aw_chans_i   ( slv_reqs_i[i].aw        ),
        .slv_aw_valids_i  ( slv_reqs_i[i].aw_valid  ),
        .slv_aw_readies_o ( slv_resps_o[i].aw_ready ),
        .slv_w_chans_i    ( slv_reqs_i[i].w         ),
        .slv_w_valids_i   ( slv_reqs_i[i].w_valid   ),
        .slv_w_readies_o  ( slv_resps_o[i].w_ready  ),
        .slv_b_chans_o    ( slv_resps_o[i].b        ),
        .slv_b_valids_o   ( slv_resps_o[i].b_valid  ),
        .slv_b_readies_i  ( slv_reqs_i[i].b_ready   ),
        .slv_ar_chans_i   ( slv_reqs_i[i].ar        ),
        .slv_ar_valids_i  ( slv_reqs_i[i].ar_valid  ),
        .slv_ar_readies_o ( slv_resps_o[i].ar_ready ),
        .slv_r_chans_o    ( slv_resps_o[i].r        ),
        .slv_r_valids_o   ( slv_resps_o[i].r_valid  ),
        .slv_r_readies_i  ( slv_reqs_i[i].r_ready   ),
        .mst_aw_chans_o   ( slv_aw_chans[i]         ),
        .mst_aw_valids_o  ( slv_aw_valids[i]        ),
        .mst_aw_readies_i ( slv_aw_readies[i]       ),
        .mst_w_chans_o    ( slv_w_chans[i]          ),
        .mst_w_valids_o   ( slv_w_valids[i]         ),
        .mst_w_readies_i  ( slv_w_readies[i]        ),
        .mst_b_chans_i    ( slv_b_chans[i]          ),
        .mst_b_valids_i   ( slv_b_valids[i]         ),
        .mst_b_readies_o  ( slv_b_readies[i]        ),
        .mst_ar_chans_o   ( slv_ar_chans[i]         ),
        .mst_ar_valids_o  ( slv_ar_valids[i]        ),
        .mst_ar_readies_i ( slv_ar_readies[i]       ),
        .mst_r_chans_i    ( slv_r_chans[i]          ),
        .mst_r_valids_i   ( slv_r_valids[i]         ),
        .mst_r_readies_o  ( slv_r_readies[i]        )
      );
    end

    //--------------------------------------
    // AW Channel
    //--------------------------------------
    rr_arb_tree #(
      .NumIn    ( NoSlvPorts    ),
      .DataType ( mst_aw_chan_t ),
      .AxiVldRdy( 1'b1          ),
      .LockIn   ( 1'b1          )
    ) i_aw_arbiter (
      .clk_i  ( clk_i           ),
      .rst_ni ( rst_ni          ),
      .flush_i( 1'b0            ),
      .rr_i   ( '0              ),
      .req_i  ( slv_aw_valids   ),
      .gnt_o  ( slv_aw_readies  ),
      .data_i ( slv_aw_chans    ),
      .gnt_i  ( aw_ready        ),
      .req_o  ( aw_valid        ),
      .data_o ( mst_aw_chan     ),
      .idx_o  (                 )
    );

    // control of the AW channel
    always_comb begin
      // default assignments
      lock_aw_valid_d = lock_aw_valid_q;
      load_aw_lock    = 1'b0;
      w_fifo_push     = 1'b0;
      mst_aw_valid    = 1'b0;
      aw_ready        = 1'b0;
      // had a downstream stall, be valid and send the AW along
      if (lock_aw_valid_q) begin
        mst_aw_valid = 1'b1;
        // transaction
        if (mst_aw_ready) begin
          aw_ready        = 1'b1;
          lock_aw_valid_d = 1'b0;
          load_aw_lock    = 1'b1;
        end
      end else begin
        if (!w_fifo_full && aw_valid) begin
          mst_aw_valid = 1'b1;
          w_fifo_push = 1'b1;
          if (mst_aw_ready) begin
            aw_ready = 1'b1;
          end else begin
            // go to lock if transaction not in this cycle
            lock_aw_valid_d = 1'b1;
            load_aw_lock    = 1'b1;
          end
        end
      end
    end

    `FFLARN(lock_aw_valid_q, lock_aw_valid_d, load_aw_lock, '0, clk_i, rst_ni)

    fifo_v3 #(
      .FALL_THROUGH ( FallThrough ),
      .DEPTH        ( MaxWTrans   ),
      .dtype        ( switch_id_t )
    ) i_w_fifo (
      .clk_i     ( clk_i                                     ),
      .rst_ni    ( rst_ni                                    ),
      .flush_i   ( 1'b0                                      ),
      .testmode_i( test_i                                    ),
      .full_o    ( w_fifo_full                               ),
      .empty_o   ( w_fifo_empty                              ),
      .usage_o   (                                           ),
      .data_i    ( mst_aw_chan.id[SlvAxiIDWidth+:MstIdxBits] ),
      .push_i    ( w_fifo_push                               ),
      .data_o    ( w_fifo_data                               ),
      .pop_i     ( w_fifo_pop                                )
    );

    spill_register #(
      .T       ( mst_aw_chan_t ),
      .Bypass  ( ~SpillAw      ) // Param indicated that we want a spill reg
    ) i_aw_spill_reg (
      .clk_i   ( clk_i               ),
      .rst_ni  ( rst_ni              ),
      .valid_i ( mst_aw_valid        ),
      .ready_o ( mst_aw_ready        ),
      .data_i  ( mst_aw_chan         ),
      .valid_o ( mst_req_o.aw_valid  ),
      .ready_i ( mst_resp_i.aw_ready ),
      .data_o  ( mst_req_o.aw        )
    );

    //--------------------------------------
    // W Channel
    //--------------------------------------
    // multiplexer
    assign mst_w_chan = slv_w_chans[w_fifo_data];
    always_comb begin
      // default assignments
      mst_w_valid   = 1'b0;
      slv_w_readies = '0;
      w_fifo_pop    = 1'b0;
      // control
      if (!w_fifo_empty) begin
        // connect the handshake
        mst_w_valid                = slv_w_valids[w_fifo_data];
        slv_w_readies[w_fifo_data] = mst_w_ready;
        // pop FIFO on a last transaction
        w_fifo_pop = slv_w_valids[w_fifo_data] & mst_w_ready & mst_w_chan.last;
      end
    end

    spill_register #(
      .T       ( w_chan_t ),
      .Bypass  ( ~SpillW  )
    ) i_w_spill_reg (
      .clk_i   ( clk_i              ),
      .rst_ni  ( rst_ni             ),
      .valid_i ( mst_w_valid        ),
      .ready_o ( mst_w_ready        ),
      .data_i  ( mst_w_chan         ),
      .valid_o ( mst_req_o.w_valid  ),
      .ready_i ( mst_resp_i.w_ready ),
      .data_o  ( mst_req_o.w        )
    );

    //--------------------------------------
    // B Channel
    //--------------------------------------
    // replicate B channels
    assign slv_b_chans  = {NoSlvPorts{mst_b_chan}};
    // control B channel handshake
    assign switch_b_id  = mst_b_chan.id[SlvAxiIDWidth+:MstIdxBits];
    assign slv_b_valids = (mst_b_valid) ? (1 << switch_b_id) : '0;

    spill_register #(
      .T       ( mst_b_chan_t ),
      .Bypass  ( ~SpillB      )
    ) i_b_spill_reg (
      .clk_i   ( clk_i                      ),
      .rst_ni  ( rst_ni                     ),
      .valid_i ( mst_resp_i.b_valid         ),
      .ready_o ( mst_req_o.b_ready          ),
      .data_i  ( mst_resp_i.b               ),
      .valid_o ( mst_b_valid                ),
      .ready_i ( slv_b_readies[switch_b_id] ),
      .data_o  ( mst_b_chan                 )
    );

    //--------------------------------------
    // AR Channel
    //--------------------------------------
    rr_arb_tree #(
      .NumIn    ( NoSlvPorts    ),
      .DataType ( mst_ar_chan_t ),
      .AxiVldRdy( 1'b1          ),
      .LockIn   ( 1'b1          )
    ) i_ar_arbiter (
      .clk_i  ( clk_i           ),
      .rst_ni ( rst_ni          ),
      .flush_i( 1'b0            ),
      .rr_i   ( '0              ),
      .req_i  ( slv_ar_valids   ),
      .gnt_o  ( slv_ar_readies  ),
      .data_i ( slv_ar_chans    ),
      .gnt_i  ( ar_ready        ),
      .req_o  ( ar_valid        ),
      .data_o ( mst_ar_chan     ),
      .idx_o  (                 )
    );

    spill_register #(
      .T       ( mst_ar_chan_t ),
      .Bypass  ( ~SpillAr      )
    ) i_ar_spill_reg (
      .clk_i   ( clk_i               ),
      .rst_ni  ( rst_ni              ),
      .valid_i ( ar_valid            ),
      .ready_o ( ar_ready            ),
      .data_i  ( mst_ar_chan         ),
      .valid_o ( mst_req_o.ar_valid  ),
      .ready_i ( mst_resp_i.ar_ready ),
      .data_o  ( mst_req_o.ar        )
    );

    //--------------------------------------
    // R Channel
    //--------------------------------------
    // The R payload is replicated to EVERY slave port in both variants below; baseline AXI simply
    // raises a one-hot valid decoded from r.id. R-MCAST additionally accepts an N-hot "deliver to
    // these ports" mask that rides with the beat through the R spill and raises valid on every
    // masked port at once (docs/icache_rmcast_design.md).
    if (!RMcastEn) begin : gen_r_unicast
      // ---- verbatim axi_mux behaviour; nothing extra is generated ----
      assign slv_r_chans  = {NoSlvPorts{mst_r_chan}};
      assign switch_r_id  = mst_r_chan.id[SlvAxiIDWidth+:MstIdxBits];
      assign slv_r_valids = (mst_r_valid) ? (1 << switch_r_id) : '0;

      spill_register #(
        .T       ( mst_r_chan_t ),
        .Bypass  ( ~SpillR      )
      ) i_r_spill_reg (
        .clk_i   ( clk_i                      ),
        .rst_ni  ( rst_ni                     ),
        .valid_i ( mst_resp_i.r_valid         ),
        .ready_o ( mst_req_o.r_ready          ),
        .data_i  ( mst_resp_i.r               ),
        .valid_o ( mst_r_valid                ),
        .ready_i ( slv_r_readies[switch_r_id] ),
        .data_o  ( mst_r_chan                 )
      );
    end else begin : gen_r_mcast
      // The mask must travel WITH the beat, so it is carried in the spill payload.
      typedef struct packed {
        logic [NoSlvPorts-1:0] mask;
        mst_r_chan_t           chan;
      } r_spill_t;
      r_spill_t              r_in, r_out;
      logic [NoSlvPorts-1:0] r_onehot, r_target, r_pend, acc_q;
      logic                  r_pop;

      assign r_in.mask = mst_r_mcast_mask_i;
      assign r_in.chan = mst_resp_i.r;

      assign mst_r_chan   = r_out.chan;
      assign slv_r_chans  = {NoSlvPorts{mst_r_chan}};
      assign switch_r_id  = mst_r_chan.id[SlvAxiIDWidth+:MstIdxBits];
      assign r_onehot     = (1 << switch_r_id);
      // No mask => EXACTLY the baseline single target.
      assign r_target     = (|r_out.mask) ? r_out.mask : r_onehot;
      // Fork/join: a port that already accepted is removed from the pending set. AXI does not
      // require simultaneous acceptance, so ports that were not ready are simply re-presented with
      // an identical payload next cycle. Best case 1 cycle, worst case N -- never worse than
      // baseline. (A shared valid + AND-reduce WITHOUT acc_q would be wrong: a tile's r_ready is a
      // level "has space", so a held beat could be captured twice -> silent instruction corruption.)
      assign r_pend       = r_target & ~acc_q;
      assign slv_r_valids = (mst_r_valid) ? r_pend : '0;
      // Pop only once every still-pending port has taken the beat.
      assign r_pop        = ~|(r_pend & ~slv_r_readies);

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)           acc_q <= '0;
        else if (!mst_r_valid) acc_q <= '0;
        else if (r_pop)        acc_q <= '0;
        else                   acc_q <= acc_q | (slv_r_readies & r_pend);
      end

      spill_register #(
        .T       ( r_spill_t ),
        .Bypass  ( ~SpillR   )
      ) i_r_spill_reg (
        .clk_i   ( clk_i               ),
        .rst_ni  ( rst_ni              ),
        .valid_i ( mst_resp_i.r_valid  ),
        .ready_o ( mst_req_o.r_ready   ),
        .data_i  ( r_in                ),
        .valid_o ( mst_r_valid         ),
        .ready_i ( r_pop               ),
        .data_o  ( r_out               )
      );

// pragma translate_off
`ifndef VERILATOR
      // Liveness watchdog: a multicast beat must eventually be taken by every masked port.
      assert property (@(posedge clk_i) disable iff (!rst_ni)
          (mst_r_valid && |r_out.mask) |-> ##[1:1024] r_pop)
        else $error("[axi_mux_mcast] multicast R beat not drained within 1024 cycles");

      // [ROC] go/no-go instrumentation (docs/icache_rmcast_design.md 5): how WIDE are the merged
      // responses actually? If the histogram mass sits at 1-2 the feature buys nothing and should be
      // dropped in favour of simply growing the caches. cyc_saved counts the cycles this feature
      // removed vs the baseline one-id-per-cycle unroll (popcount-1 per multicast beat).
      longint unsigned roc_beats, roc_mcast_beats, roc_cyc_saved, roc_hold_cyc;
      longint unsigned roc_hist [0:NoSlvPorts];
      int unsigned     roc_pc;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          roc_beats <= '0; roc_mcast_beats <= '0; roc_cyc_saved <= '0; roc_hold_cyc <= '0;
          for (int k = 0; k <= NoSlvPorts; k++) roc_hist[k] <= '0;
        end else begin
          // A beat is "done" on the cycle it is popped.
          if (mst_r_valid && r_pop) begin
            roc_pc = $countones(r_target);
            roc_beats <= roc_beats + 1;
            roc_hist[roc_pc] <= roc_hist[roc_pc] + 1;
            if (|r_out.mask) begin
              roc_mcast_beats <= roc_mcast_beats + 1;
              roc_cyc_saved   <= roc_cyc_saved + (roc_pc - 1);
            end
          end
          // Cycles a beat sat here waiting for stragglers (the cost this feature still pays).
          if (mst_r_valid && !r_pop) roc_hold_cyc <= roc_hold_cyc + 1;
        end
      end
      final begin
        $display("[ROC] %m beats=%0d mcast_beats=%0d cyc_saved=%0d hold_cyc=%0d",
                 roc_beats, roc_mcast_beats, roc_cyc_saved, roc_hold_cyc);
        for (int k = 1; k <= NoSlvPorts; k++)
          if (roc_hist[k] != 0) $display("[ROC]   fanout=%0d count=%0d", k, roc_hist[k]);
      end
`endif
// pragma translate_on
    end
  end

// pragma translate_off
`ifndef VERILATOR
  initial begin
    assert (SlvAxiIDWidth > 0) else $fatal(1, "AXI ID width of slave ports must be non-zero!");
    assert (NoSlvPorts > 0) else $fatal(1, "Number of slave ports must be non-zero!");
    assert (MaxWTrans > 0)
      else $fatal(1, "Maximum number of outstanding writes must be non-zero!");
    assert (MstAxiIDWidth >= SlvAxiIDWidth + $clog2(NoSlvPorts))
      else $fatal(1, "AXI ID width of master ports must be wide enough to identify slave ports!");
    // Assert ID widths (one slave is sufficient since they all have the same type).
    assert ($unsigned($bits(slv_reqs_i[0].aw.id)) == SlvAxiIDWidth)
      else $fatal(1, "ID width of AW channel of slave ports does not match parameter!");
    assert ($unsigned($bits(slv_reqs_i[0].ar.id)) == SlvAxiIDWidth)
      else $fatal(1, "ID width of AR channel of slave ports does not match parameter!");
    assert ($unsigned($bits(slv_resps_o[0].b.id)) == SlvAxiIDWidth)
      else $fatal(1, "ID width of B channel of slave ports does not match parameter!");
    assert ($unsigned($bits(slv_resps_o[0].r.id)) == SlvAxiIDWidth)
      else $fatal(1, "ID width of R channel of slave ports does not match parameter!");
    assert ($unsigned($bits(mst_req_o.aw.id)) == MstAxiIDWidth)
      else $fatal(1, "ID width of AW channel of master port is wrong!");
    assert ($unsigned($bits(mst_req_o.ar.id)) == MstAxiIDWidth)
      else $fatal(1, "ID width of AR channel of master port is wrong!");
    assert ($unsigned($bits(mst_resp_i.b.id)) == MstAxiIDWidth)
      else $fatal(1, "ID width of B channel of master port is wrong!");
    assert ($unsigned($bits(mst_resp_i.r.id)) == MstAxiIDWidth)
      else $fatal(1, "ID width of R channel of master port is wrong!");
  end
`endif
// pragma translate_on
endmodule
