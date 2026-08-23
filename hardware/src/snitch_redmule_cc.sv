// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "hci_helpers.svh"

// Snitch owner core and its private RedMulE engine. Shared tile resources such
// as instruction caches, TCDM address routing, memory banks, and the NoC remain
// outside this compute-complex boundary.
module snitch_redmule_cc
  import cf_math_pkg::idx_width;
  import hci_package::*;
#(
  parameter logic [31:0] BootAddr        = `ifdef BOOT_ADDR `BOOT_ADDR `else 32'h0000_1000 `endif,
  parameter logic [31:0] RMCfgBaseAddr   = 32'h4002_0000,
  parameter logic [31:0] RMCfgMask       = 32'hffff_ff00,
  parameter int unsigned RMArrayHeight   = `ifdef ARRAY_HEIGHT `ARRAY_HEIGHT `else 4 `endif,
  parameter int unsigned RMArrayWidth    = `ifdef ARRAY_WIDTH `ARRAY_WIDTH `else 12 `endif,
  parameter int unsigned RMPipeRegs      = `ifdef PIPE_REGS `PIPE_REGS `else 3 `endif,
  parameter int unsigned RMRobDepth      = `ifdef ROB_DEPTH `ROB_DEPTH `else 16 `endif,
  parameter int unsigned RMNumStreams    = 4,
  // Dependent parameters. Do not override.
  parameter int unsigned RMDataWidth     = 16 * RMArrayHeight * (RMPipeRegs + 1),
  parameter int unsigned RMMasterPorts   = RMDataWidth / 32,
  parameter int unsigned RMIdWidth       = idx_width(RMNumStreams * RMRobDepth)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic test_mode_i,
  input  logic [31:0] hart_id_i,

  // Instruction port.
  output logic [31:0] inst_addr_o,
  input  logic [31:0] inst_data_i,
  output logic inst_valid_o,
  input  logic inst_ready_i,

  // Optional tile-shared operational unit.
  output snitch_pkg::acc_req_t sh_acc_req_o,
  output logic sh_acc_req_valid_o,
  input  logic sh_acc_req_ready_i,
  input  snitch_pkg::acc_resp_t sh_acc_resp_i,
  input  logic sh_acc_resp_valid_i,
  output logic sh_acc_resp_ready_o,

  // Snitch data port after the private RedMulE configuration window has been
  // removed. The tile remains responsible for TCDM/SoC address routing.
  output logic [31:0] data_qaddr_o,
  output logic data_qwrite_o,
  output logic [3:0] data_qamo_o,
  output logic [31:0] data_qdata_o,
  output logic [3:0] data_qstrb_o,
  output snitch_pkg::meta_id_t data_qid_o,
  output logic data_qvalid_o,
  input  logic data_qready_i,
  input  logic [31:0] data_pdata_i,
  input  logic data_perror_i,
  input  snitch_pkg::meta_id_t data_pid_i,
  input  logic data_pvalid_i,
  output logic data_pready_o,

  // RedMulE memory lanes. Each lane is an independent backpressured 32-bit
  // client; the compute complex keeps native RedMulE beats atomic internally.
  output logic [RMMasterPorts-1:0][31:0] rm_tcdm_req_addr_o,
  output logic [RMMasterPorts-1:0] rm_tcdm_req_write_o,
  output logic [RMMasterPorts-1:0][3:0] rm_tcdm_req_amo_o,
  output logic [RMMasterPorts-1:0][31:0] rm_tcdm_req_data_o,
  output logic [RMMasterPorts-1:0][3:0] rm_tcdm_req_strb_o,
  output logic [RMMasterPorts-1:0][RMIdWidth-1:0] rm_tcdm_req_id_o,
  output logic [RMMasterPorts-1:0] rm_tcdm_req_valid_o,
  input  logic [RMMasterPorts-1:0] rm_tcdm_req_ready_i,
  input  logic [RMMasterPorts-1:0][31:0] rm_tcdm_resp_data_i,
  input  logic [RMMasterPorts-1:0][RMIdWidth-1:0] rm_tcdm_resp_id_i,
  input  logic [RMMasterPorts-1:0] rm_tcdm_resp_valid_i,
  output logic [RMMasterPorts-1:0] rm_tcdm_resp_ready_o,

  input  logic wake_up_sync_i,
  output logic redmule_busy_o,
  output logic [1:0] redmule_evt_o,
  output snitch_pkg::core_events_t core_events_o
);

  typedef struct packed {
    logic [31:0] addr;
    logic [RMIdWidth-1:0] id;
    logic [3:0] amo;
    logic write;
    logic [31:0] data;
    logic [3:0] strb;
  } rm_dreq_t;

  typedef struct packed {
    logic [31:0] data;
    logic [RMIdWidth-1:0] id;
    logic write;
    logic error;
  } rm_dresp_t;

  /*********************
   *  Snitch owner core
   *********************/

  snitch_pkg::dreq_t core_data_req;
  snitch_pkg::dresp_t core_data_resp;
  logic core_data_req_valid;
  logic core_data_req_ready;
  logic core_data_resp_valid;
  logic core_data_resp_ready;

  mempool_cc #(
    .BootAddr(BootAddr)
  ) riscv_core (
    .clk_i,
    .rst_ni,
    .hart_id_i,
    .inst_addr_o,
    .inst_data_i,
    .inst_valid_o,
    .inst_ready_i,
    .sh_acc_req_o,
    .sh_acc_req_valid_o,
    .sh_acc_req_ready_i,
    .sh_acc_resp_i,
    .sh_acc_resp_valid_i,
    .sh_acc_resp_ready_o,
    .data_qaddr_o     (core_data_req.addr ),
    .data_qwrite_o    (core_data_req.write),
    .data_qamo_o      (core_data_req.amo  ),
    .data_qdata_o     (core_data_req.data ),
    .data_qstrb_o     (core_data_req.strb ),
    .data_qid_o       (core_data_req.id   ),
    .data_qvalid_o    (core_data_req_valid),
    .data_qready_i    (core_data_req_ready),
    .data_pdata_i     (core_data_resp.data ),
    .data_perror_i    (core_data_resp.error),
    .data_pid_i       (core_data_resp.id   ),
    .data_pvalid_i    (core_data_resp_valid),
    .data_pready_o    (core_data_resp_ready),
    .wake_up_sync_i   (wake_up_sync_i | redmule_evt_o[0]),
    .core_events_o
  );

  /***********************************
   *  Private RedMulE configuration
   ***********************************/

  snitch_pkg::dreq_t rm_cfg_req;
  snitch_pkg::dresp_t rm_cfg_resp;
  logic rm_cfg_req_valid;
  logic rm_cfg_req_ready;
  logic rm_cfg_resp_valid;
  logic rm_cfg_resp_ready;
  logic rm_cfg_select;

  snitch_pkg::dresp_t system_data_resp;
  snitch_pkg::dresp_t [1:0] core_resp_inputs;
  logic [1:0] core_resp_valid;
  logic [1:0] core_resp_ready;

  assign rm_cfg_select =
      (core_data_req.addr & RMCfgMask) == (RMCfgBaseAddr & RMCfgMask);

  assign rm_cfg_req       = core_data_req;
  assign rm_cfg_req_valid = core_data_req_valid && rm_cfg_select;

  assign data_qaddr_o  = core_data_req.addr;
  assign data_qwrite_o = core_data_req.write;
  assign data_qamo_o   = core_data_req.amo;
  assign data_qdata_o  = core_data_req.data;
  assign data_qstrb_o  = core_data_req.strb;
  assign data_qid_o    = core_data_req.id;
  assign data_qvalid_o = core_data_req_valid && !rm_cfg_select;

  assign core_data_req_ready = rm_cfg_select ? rm_cfg_req_ready : data_qready_i;

  assign system_data_resp = '{
    data:  data_pdata_i,
    id:    data_pid_i,
    write: 1'b0,
    error: data_perror_i
  };

  assign core_resp_inputs = {system_data_resp, rm_cfg_resp};
  assign core_resp_valid  = {data_pvalid_i, rm_cfg_resp_valid};
  assign {data_pready_o, rm_cfg_resp_ready} = core_resp_ready;

  stream_arbiter #(
    .DATA_T (snitch_pkg::dresp_t),
    .N_INP  (2                   ),
    .ARBITER("rr"                )
  ) i_core_resp_arbiter (
    .clk_i,
    .rst_ni,
    .inp_data_i (core_resp_inputs    ),
    .inp_valid_i(core_resp_valid     ),
    .inp_ready_o(core_resp_ready     ),
    .oup_data_o (core_data_resp      ),
    .oup_valid_o(core_data_resp_valid),
    .oup_ready_i(core_data_resp_ready)
  );

  // Keep ID_WIDTH non-zero: the HWPE interface declares [ID_WIDTH-1:0].
  hwpe_ctrl_intf_periph #(
    .ID_WIDTH(8)
  ) redmule_rmcfg (
    .clk(clk_i)
  );

  snitch_hwpe_cfg_adapter #(
    .req_t (snitch_pkg::dreq_t ),
    .resp_t(snitch_pkg::dresp_t)
  ) i_redmule_cfg_adapter (
    .clk_i,
    .rst_ni,
    .req_i        (rm_cfg_req       ),
    .req_valid_i  (rm_cfg_req_valid ),
    .req_ready_o  (rm_cfg_req_ready ),
    .resp_o       (rm_cfg_resp      ),
    .resp_valid_o (rm_cfg_resp_valid),
    .resp_ready_i (rm_cfg_resp_ready),
    .periph       (redmule_rmcfg    )
  );

  /*******************
   *  RedMulE engine
   *******************/

  localparam hci_size_parameter_t `HCI_SIZE_PARAM(tcdm) = '{
    DW:  RMDataWidth,
    AW:  32,
    BW:  4,
    UW:  idx_width(RMRobDepth),
    IW:  idx_width(RMNumStreams),
    EW:  0,
    EHW: 0
  };

  hci_variablelatency_intf #(
    .DW(RMDataWidth          ),
    .UW(idx_width(RMRobDepth)),
    .IW(idx_width(RMNumStreams))
  ) tcdm (
    .clk(clk_i)
  );

  // XIF is required by redmule_top's signature but disabled for this MMIO design.
  cv32e40x_if_xif core_xif ();

  redmule_top #(
    .N_CORES      (1                    ),
    .DW           (RMDataWidth          ),
    .UW           (idx_width(RMRobDepth)),
    .X_EXT        (0                    ),
    .Height       (RMArrayHeight        ),
    .Width        (RMArrayWidth         ),
    .NumPipeRegs  (RMPipeRegs           ),
    .`HCI_SIZE_PARAM(tcdm)(`HCI_SIZE_PARAM(tcdm))
  ) i_redmule_top (
    .clk_i,
    .rst_ni,
    .test_mode_i,
    .busy_o             (redmule_busy_o            ),
    .evt_o              (redmule_evt_o             ),
    .tcdm,
    .xif_issue_if_i     (core_xif.coproc_issue     ),
    .xif_result_if_o    (core_xif.coproc_result    ),
    .xif_compressed_if_i(core_xif.coproc_compressed),
    .xif_mem_if_o       (core_xif.coproc_mem       ),
    .periph             (redmule_rmcfg             )
  );

  /************************
   *  Atomic HCI lane bridge
   ************************/

  rm_dreq_t [RMMasterPorts-1:0] redmule_req;
  logic [RMMasterPorts-1:0] redmule_req_valid;
  logic [RMMasterPorts-1:0] redmule_req_ready;
  rm_dresp_t [RMMasterPorts-1:0] redmule_resp;
  logic [RMMasterPorts-1:0] redmule_resp_valid;
  logic [RMMasterPorts-1:0] redmule_resp_ready;

  for (genvar p = 0; p < RMMasterPorts; p++) begin : gen_hci_unpack
    assign redmule_req[p].addr  = tcdm.req_add + p * 4;
    assign redmule_req[p].write = ~tcdm.req_wen;
    assign redmule_req[p].strb  = tcdm.req_be[(p+1)*4-1:p*4];
    assign redmule_req[p].data  = tcdm.req_data[(p+1)*32-1:p*32];
    assign redmule_req[p].amo   = '0;
    assign redmule_req[p].id = RMIdWidth'({tcdm.req_id, tcdm.req_user});
    assign tcdm.resp_data[(p+1)*32-1:p*32] = redmule_resp[p].data;
  end : gen_hci_unpack

  assign redmule_req_valid  = {RMMasterPorts{tcdm.req_valid}};
  assign tcdm.req_ready     = &redmule_req_ready;
  assign tcdm.resp_valid    = &redmule_resp_valid;
  assign redmule_resp_ready = {RMMasterPorts{tcdm.resp_ready}};
  assign tcdm.resp_id = redmule_resp[0].id[
      idx_width(RMRobDepth) +: idx_width(RMNumStreams)];
  assign tcdm.resp_user = redmule_resp[0].id[idx_width(RMRobDepth)-1:0];

  rm_dreq_t [RMMasterPorts-1:0] redmule_req_q;
  logic [RMMasterPorts-1:0] redmule_req_qvalid;
  logic [RMMasterPorts-1:0] redmule_req_qready;
  rm_dresp_t [RMMasterPorts-1:0] redmule_resp_q;
  logic [RMMasterPorts-1:0] redmule_resp_qvalid;
  logic [RMMasterPorts-1:0] redmule_resp_qready;

  rm_dreq_t [RMMasterPorts-1:0] redmule_tcdm_req;
  logic [RMMasterPorts-1:0] redmule_tcdm_req_valid;
  logic [RMMasterPorts-1:0] redmule_tcdm_req_ready;
  rm_dresp_t [RMMasterPorts-1:0] redmule_tcdm_resp;
  logic [RMMasterPorts-1:0] redmule_tcdm_resp_valid;
  logic [RMMasterPorts-1:0] redmule_tcdm_resp_ready;

  logic [RMMasterPorts-1:0] redmule_handshake_d;
  logic [RMMasterPorts-1:0] redmule_handshake_q;

  for (genvar p = 0; p < RMMasterPorts; p++) begin : gen_redmule_regs
    stream_register #(
      .T(rm_dreq_t)
    ) i_redmule_req_register (
      .clk_i,
      .rst_ni,
      .clr_i      (1'b0                 ),
      .testmode_i (test_mode_i          ),
      .valid_i    (redmule_req_valid[p] ),
      .ready_o    (redmule_req_ready[p] ),
      .data_i     (redmule_req[p]       ),
      .valid_o    (redmule_req_qvalid[p]),
      .ready_i    (redmule_req_qready[p]),
      .data_o     (redmule_req_q[p]     )
    );

    stream_register #(
      .T(rm_dresp_t)
    ) i_redmule_resp_register (
      .clk_i,
      .rst_ni,
      .clr_i      (1'b0                  ),
      .testmode_i (test_mode_i           ),
      .valid_o    (redmule_resp_valid[p] ),
      .ready_i    (redmule_resp_ready[p] ),
      .data_o     (redmule_resp[p]       ),
      .valid_i    (redmule_resp_qvalid[p]),
      .ready_o    (redmule_resp_qready[p]),
      .data_i     (redmule_resp_q[p]     )
    );

    assign rm_tcdm_req_addr_o[p]  = redmule_tcdm_req[p].addr;
    assign rm_tcdm_req_write_o[p] = redmule_tcdm_req[p].write;
    assign rm_tcdm_req_amo_o[p]   = redmule_tcdm_req[p].amo;
    assign rm_tcdm_req_data_o[p]  = redmule_tcdm_req[p].data;
    assign rm_tcdm_req_strb_o[p]  = redmule_tcdm_req[p].strb;
    assign rm_tcdm_req_id_o[p]    = redmule_tcdm_req[p].id;

    assign redmule_tcdm_resp[p] = '{
      data:  rm_tcdm_resp_data_i[p],
      id:    rm_tcdm_resp_id_i[p],
      write: 1'b0,
      error: 1'b0
    };
  end : gen_redmule_regs

  assign rm_tcdm_req_valid_o    = redmule_tcdm_req_valid;
  assign redmule_tcdm_req_ready = rm_tcdm_req_ready_i;
  assign redmule_tcdm_resp_valid = rm_tcdm_resp_valid_i;
  assign rm_tcdm_resp_ready_o    = redmule_tcdm_resp_ready;

  // Each lane may accept on a different cycle, but the native HCI beat advances
  // only after every lane has accepted exactly once.
  assign redmule_handshake_d = (&redmule_req_qready) ? '0 : redmule_req_qready;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      redmule_handshake_q <= '0;
    end else begin
      redmule_handshake_q <= redmule_handshake_d;
    end
  end

  assign redmule_tcdm_req       = redmule_req_q;
  assign redmule_tcdm_req_valid = ~redmule_handshake_q & redmule_req_qvalid;
  assign redmule_req_qready =
      redmule_handshake_q | (redmule_tcdm_req_valid & redmule_tcdm_req_ready);

  transactions_table #(
    .NumPorts       (RMMasterPorts                       ),
    .NumTransactions((RMNumStreams - 1) * RMRobDepth    ),
    .resp_t         (rm_dresp_t                          )
  ) i_redmule_transactions_table (
    .clk_i,
    .rst_ni,
    .resp_payload_i(redmule_tcdm_resp      ),
    .resp_valid_i  (redmule_tcdm_resp_valid),
    .resp_ready_o  (redmule_tcdm_resp_ready),
    .resp_payload_o(redmule_resp_q          ),
    .resp_valid_o  (redmule_resp_qvalid     ),
    .resp_ready_i  (redmule_resp_qready     )
  );

  /******************
   *  Configuration checks
   ******************/

  if (RMDataWidth == 0 || RMDataWidth % 32 != 0) begin : gen_invalid_data_width
    $fatal(1, "snitch_redmule_cc requires a positive 32-bit-aligned RMDataWidth");
  end

  if (RMNumStreams < 2 || RMRobDepth < 1) begin : gen_invalid_transaction_config
    $fatal(1, "snitch_redmule_cc requires at least two streams and one ROB entry");
  end

  if (RMIdWidth < idx_width(RMNumStreams) + idx_width(RMRobDepth)) begin : gen_invalid_id_width
    $fatal(1, "snitch_redmule_cc requires enough bits for stream and ROB IDs");
  end

endmodule : snitch_redmule_cc
