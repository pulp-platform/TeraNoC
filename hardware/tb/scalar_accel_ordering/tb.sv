`timescale 1ns/1ps

// Exercise the real Snitch decoder, LSU and counters with delayed accelerator completion.
module tb;
  parameter bit Ordering = 0;
  typedef struct packed {
    logic accept, writeback, loadstore, exception, isfloat;
  } issue_rsp_t;

  logic clk, rst;
  logic [31:0] insn;
  logic [1:0] finished, store_finished, sent;
  logic acc_valid, data_valid, data_ready, response_valid;
  snitch_pkg::meta_id_t request_id, response_id;
  issue_rsp_t issue_rsp;

  snitch #(
    .RVV(1), .EnScalarAccelMemOrdering(Ordering), .acc_issue_rsp_t(issue_rsp_t)
  ) dut (
    .clk_i(clk), .rst_i(rst), .hart_id_i('0),
    .inst_data_i(insn), .inst_ready_i(1'b1), .inst_addr_o(), .inst_valid_o(),
    .acc_qaddr_o(), .acc_qid_o(), .acc_qdata_op_o(),
    .acc_qdata_arga_o(), .acc_qdata_argb_o(), .acc_qdata_argc_o(), .acc_pready_o(),
    .acc_qvalid_o(acc_valid), .acc_qready_i(1'b1),
    .acc_qdata_rsp_i(issue_rsp), .acc_pid_i('0), .acc_pdata_i('0),
    .acc_pwrite_i(1'b0), .acc_perror_i(1'b0), .acc_pvalid_i(1'b0),
    .acc_mem_finished_i(finished), .acc_mem_str_finished_i(store_finished),
    .acc_mem_req_sent_i(sent), .acc_mem_vec_accepted_i(1'b0),
    .data_qvalid_o(data_valid), .data_qready_i(data_ready), .data_qid_o(request_id),
    .data_pdata_i('0), .data_perror_i(1'b0), .data_pid_i(response_id),
    .data_pvalid_i(response_valid), .wake_up_sync_i(1'b0), .fpu_status_i('0),
    .data_qaddr_o(), .data_qwrite_o(), .data_qamo_o(), .data_qdata_o(),
    .data_qstrb_o(), .data_pready_o(), .fpu_rnd_mode_o(), .fpu_fmt_mode_o(),
    .core_events_o()
  );

  task automatic tick;
    #5 clk = 1;
    #5 clk = 0;
    #1;
  endtask

  task automatic reset_core;
    clk = 0;
    rst = 1;
    insn = 32'h00000013; // nop
    finished = 0;
    store_finished = 0;
    sent = 0;
    data_ready = 0;
    response_valid = 0;
    response_id = 0;
    issue_rsp = '{accept: 1, loadstore: 1, default: 0};
    tick();
    rst = 0;
    #1;
  endtask

  task automatic offload(input bit store_op);
    insn = store_op ? 32'h02006027 : 32'h02006007; // vse32/vle32 v0,(x0)
    #1;
    if (acc_valid !== 1 || dut.stall !== 0) $fatal(1, "Offload not accepted");
    tick();
    insn = 32'h00000013;
    #1;
  endtask

  task automatic finish_op(input bit store_op);
    insn = 32'h00000013;
    finished = 2'b10;
    store_finished = store_op ? 2'b10 : 0;
    sent = 2'b10;
    tick();
    finished = 0;
    store_finished = 0;
    sent = 0;
    #1;
  endtask

  initial begin
    // Four combinations, with vector address 0 and scalar address 4.
    for (int vstore = 0; vstore < 2; vstore++) begin
      for (int sstore = 0; sstore < 2; sstore++) begin
        reset_core();
        offload(1'(vstore));
        if (dut.acc_mem_cnt_q != 1 || dut.acc_mem_str_cnt_q != vstore)
          $fatal(1, "Offload bookkeeping failed");
        insn = sstore ? 32'h00002223 : 32'h00402003; // sw x0,4(x0) / lw x0,4(x0)
        #1;
        if (data_valid !== !(Ordering && (vstore || sstore)))
          $fatal(1, "Wrong overlap: ordering=%0d vector_store=%0d scalar_store=%0d",
                 Ordering, vstore, sstore);
        // Backpressure must hold the instruction even in relaxed mode.
        if (dut.stall !== 1) $fatal(1, "Lost scalar backpressure");
        finish_op(1'(vstore));
        insn = sstore ? 32'h00002223 : 32'h00402003;
        data_ready = 1;
        #1;
        if (data_valid !== 1 || dut.stall !== 0)
          $fatal(1, "Scalar did not unblock after accelerator completion");
      end
    end

    // Full counter must still reject both scalar memory and the eighth offload.
    reset_core();
    repeat (7) offload(0);
    insn = 32'h02006007;
    #1;
    if (acc_valid !== 0 || dut.stall !== 1 || dut.acc_mem_cnt_q != 7)
      $fatal(1, "Accelerator capacity guard failed");
    insn = 32'h00402003;
    data_ready = 1;
    #1;
    if (data_valid !== 0 || dut.stall !== 1) $fatal(1, "Scalar capacity guard failed");
    finish_op(0);
    insn = 32'h02006007;
    #1;
    if (acc_valid !== 1 || dut.acc_mem_cnt_q != 6) $fatal(1, "Capacity did not recover");

    // Request-sent fence releases before the full completion fence, in both modes.
    reset_core();
    offload(1);
    insn = 32'h12000073; // sfence.vma x0,x0 (custom request-sent fence)
    #1;
    if (dut.fence_stall !== 1) $fatal(1, "Request fence did not wait");
    sent = 2'b10;
    tick();
    sent = 0;
    #1;
    if (dut.fence_stall !== 0) $fatal(1, "Request fence did not release");
    tick(); // Retire the previously stalled instruction before changing it.
    insn = 32'h0ff0000f; // fence iorw,iorw
    #1;
    if (dut.fence_stall !== 1) $fatal(1, "Full fence ignored accelerator completion");
    finished = 2'b10;
    store_finished = 2'b10;
    tick();
    finished = 0;
    store_finished = 0;
    #1;
    if (dut.fence_stall !== 0 || dut.acc_mem_cnt_q != 0 || dut.acc_mem_str_cnt_q != 0)
      $fatal(1, "Full fence did not release after completion");

    // Full fence also waits for the integer store acknowledgement.
    reset_core();
    insn = 32'h00002223;
    data_ready = 1;
    #1;
    response_id = request_id;
    tick();
    insn = 32'h0ff0000f;
    #1;
    if (dut.fence_stall !== 1) $fatal(1, "Full fence ignored integer LSU");
    response_valid = 1;
    tick();
    response_valid = 0;
    #1;
    if (dut.fence_stall !== 0) $fatal(1, "Integer fence did not release");
    $display("PASS scalar/accelerator ordering=%0d", Ordering);
    $finish;
  end
endmodule
