// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: SHL-0.51

// Drive the real tile shims, request registers, group interconnect, and SRAMs.
// Keep CPUs idle; full-system software validation covers instruction execution.
module mempool_tb;
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
  timeunit 1ns;
  timeprecision 1ps;

  wire csr_trace_any_global = 1'b0;
  logic clk = 0;
  logic rst_n;
  group_id_t group_id;
  addr_t [NumTilesPerGroup-1:0] address;
  data_t [NumTilesPerGroup-1:0] data;
  logic [NumTilesPerGroup-1:0] valid, write, ready;
  data_t [NumTilesPerGroup-1:0] response;
  int unsigned response_count[NumTilesPerGroup];
  int unsigned baseline[NumTilesPerGroup];
  addr_t control, sram;

  always #5 clk = ~clk;
  mempool_group dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .scan_enable_i(1'b0), .scan_data_i(1'b0), .scan_data_o(), .group_id_i(group_id),
    .tcdm_master_req_o(), .tcdm_master_req_valid_o(), .tcdm_master_req_ready_i('0),
    .tcdm_master_resp_i('0), .tcdm_master_resp_valid_i('0), .tcdm_master_resp_ready_o(),
    .tcdm_slave_req_i('0), .tcdm_slave_req_valid_i('0), .tcdm_slave_req_ready_o(),
    .tcdm_slave_resp_o(), .tcdm_slave_resp_valid_o(), .tcdm_slave_resp_ready_i('0),
    .wake_up_i('0), .ro_cache_ctrl_i(ro_cache_ctrl_default), .dma_req_i('0), .dma_req_valid_i(1'b0),
    .dma_req_ready_o(), .dma_meta_o(), .axi_mst_req_o(), .axi_mst_resp_i('0)
  );

  for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_drive
    initial begin
      force dut.gen_tiles[t].i_tile.snitch_data_qaddr[0][0] = address[t];
      force dut.gen_tiles[t].i_tile.snitch_data_qvalid[0][0] = valid[t];
      force dut.gen_tiles[t].i_tile.snitch_data_qwrite[0][0] = write[t];
      force dut.gen_tiles[t].i_tile.snitch_data_qdata[0][0] = data[t];
      force dut.gen_tiles[t].i_tile.snitch_data_qamo[0][0] = '0;
      force dut.gen_tiles[t].i_tile.snitch_data_qstrb[0][0] = '1;
      force dut.gen_tiles[t].i_tile.snitch_data_qid[0][0] = '0;
      force dut.gen_tiles[t].i_tile.snitch_data_qburst_len[0][0] = BurstLenWidth'(1);
      force dut.gen_tiles[t].i_tile.snitch_data_pready = '1;
      force dut.gen_tiles[t].i_tile.snitch_data_pvalid = '0;
    end
    for (genvar p = 1; p < NumDataPortsPerCore; p++) begin : gen_idle_port
      initial force dut.gen_tiles[t].i_tile.snitch_data_qvalid[0][p] = 1'b0;
    end
    assign ready[t] = dut.gen_tiles[t].i_tile.snitch_data_qready[0][0];
    always @(posedge clk) begin
      if (!rst_n) begin
        response_count[t] = 0;
        response[t] = '0;
      end else if (dut.tcdm_master_resp_valid[0][t] && dut.tcdm_master_resp_ready[0][t]) begin
        response_count[t]++;
        response[t] = dut.tcdm_master_resp[0][t].rdata.data;
      end
    end
  end

  task automatic issue(input int unsigned tile, input addr_t addr,
                       input bit is_write, input data_t value);
    @(negedge clk);
    address[tile] = addr;
    write[tile] = is_write;
    data[tile] = value;
    valid[tile] = 1;
    do @(posedge clk); while (!ready[tile]);
    @(negedge clk);
    valid[tile] = 0;
  endtask

  task automatic transact(input int unsigned tile, input addr_t addr,
                          input bit is_write, input data_t value);
    int unsigned target;
    target = response_count[tile] + 1;
    issue(tile, addr, is_write, value);
    while (response_count[tile] < target) @(negedge clk);
  endtask

  initial begin
    rst_n = 0;
    group_id = group_id_t'(NumGroups-1);
    address = '0;
    data = '0;
    valid = '0;
    write = '0;
    repeat (5) @(negedge clk);
    rst_n = 1;
    repeat (5) @(negedge clk);
    control = GroupControlStart + group_id * BeWidth * NumBanksPerGroup;
    sram = GroupControlWord * BeWidth * NumBanks + group_id * BeWidth * NumBanksPerGroup;

    // Same-group SRAM requests at the first formerly reserved word.
    for (int unsigned t = 0; t < NumTilesPerGroup; t++) begin
      transact(t, sram + ((t+1) % NumTilesPerGroup) * BeWidth * NumBanksPerTile,
               1, 32'hca000000 + t);
      transact(t, sram + ((t+1) % NumTilesPerGroup) * BeWidth * NumBanksPerTile, 0, 0);
      if (response[t] != 32'hca000000 + t)
        $fatal(1, "Recovered SRAM read mismatch tile=%0d", t);
    end

    // CSR index 15, own-tile target, read/write acknowledgements.
    transact(0, control + 15 * BeWidth * NumBanks + 3 * BeWidth, 1, 0);
    transact(0, control + 15 * BeWidth * NumBanks + 3 * BeWidth, 0, 0);
    if (response[0] != 0) $fatal(1, "MSHR status mismatch");
    transact(0, control + BeWidth, 1, NumTilesPerGroup);
    transact(0, control + 2 * BeWidth, 1, (1 << NumTilesPerGroup)-1);

    for (int unsigned round = 0; round < 2; round++) begin
      for (int unsigned t = 0; t < NumTilesPerGroup; t++) baseline[t] = response_count[t];
      for (int unsigned t = 0; t < NumTilesPerGroup-1; t++)
        issue(t, control + t * BeWidth * NumBanksPerTile, 0, 0);
      repeat (20) @(negedge clk);
      for (int unsigned t = 0; t < NumTilesPerGroup; t++)
        if (response_count[t] != baseline[t]) $fatal(1, "Premature barrier response");
      issue(NumTilesPerGroup-1, control + (NumTilesPerGroup-1) * BeWidth * NumBanksPerTile, 0, 0);
      for (int unsigned t = 0; t < NumTilesPerGroup; t++)
        while (response_count[t] < baseline[t]+1) @(negedge clk);
    end
    repeat (10) @(negedge clk);
    if (dut.gen_group_barrier.i_group_barrier.bar_release_cnt_dbg != 2)
      $fatal(1, "Expected two completed barrier rendezvous");
    $display("PASS group-control transport: groups=%0d group=%0d arrivals=%0d bar_rel=%0d",
             NumGroups, group_id, 2 * NumTilesPerGroup,
             dut.gen_group_barrier.i_group_barrier.bar_release_cnt_dbg);
    $finish;
  end
  initial begin
    repeat (10000) @(posedge clk);
    $fatal(1, "Group-control transport timeout");
  end
endmodule
