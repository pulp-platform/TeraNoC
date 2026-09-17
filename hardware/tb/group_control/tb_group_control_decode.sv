// Copyright 2026 ETH Zurich and University of Bologna.
// SPDX-License-Identifier: SHL-0.51

// Exercise the production tile decoder at every group/tile, without booting CPUs.
module mempool_tb;
  import mempool_pkg::*;
  import cf_math_pkg::idx_width;
  timeunit 1ns;
  timeprecision 1ps;

  wire csr_trace_any_global = 1'b0;
  logic clk, rst_n;
  logic [idx_width(NumTiles)-1:0] tile_id;
  addr_t address;
  int unsigned checks;

  mempool_tile dut (
    .clk_i(clk), .rst_ni(rst_n), .scan_enable_i(1'b0), .scan_data_i(1'b0),
    .scan_data_o(), .tile_id_i(tile_id),
    .tcdm_master_req_o(), .tcdm_master_req_valid_o(), .tcdm_master_req_ready_i('0),
    .tcdm_master_resp_i('0), .tcdm_master_resp_valid_i('0), .tcdm_master_resp_ready_o(),
    .tcdm_slave_req_i('0), .tcdm_slave_req_valid_i('0), .tcdm_slave_req_ready_o(),
    .tcdm_slave_resp_o(), .tcdm_slave_resp_valid_o(), .tcdm_slave_resp_ready_i('0),
    .tcdm_dma_req_i('0), .tcdm_dma_req_valid_i(1'b0), .tcdm_dma_req_ready_o(),
    .tcdm_dma_resp_o(), .tcdm_dma_resp_valid_o(), .tcdm_dma_resp_ready_i(1'b0),
    .axi_mst_req_o(), .axi_mst_resp_i('0), .wake_up_i('0)
  );

  task automatic check(input addr_t addr, input logic [2:0] route, input bit control);
    address = addr;
    #1;
    if ({dut.soc_data_qvalid[0], dut.local_req_interco_valid_raw[0],
         dut.remote_req_interco_valid_raw[0]} !== route)
      $fatal(1, "tile=%0d address=%h routing mismatch", tile_id, address);
    if (route[0] && dut.remote_req_interco_raw[0].group_ctrl !== control)
      $fatal(1, "tile=%0d address=%h control selector mismatch", tile_id, address);
    checks++;
  endtask

  initial begin
    if (TCDMAddrMemWidth != 8 || NumCoresPerTile != 1 || NumGroups < 2)
      $fatal(1, "Decoder bench expects current Spatz mesh geometry.");
    clk = 0;
    rst_n = 0;
    tile_id = 0;
    address = 0;
    checks = 0;
    // Keep the clock stopped: only combinational decoding is under test.
    force dut.snitch_data_qaddr[0][0] = address;
    force dut.snitch_data_qvalid[0][0] = 1'b1;
    force dut.snitch_data_qwrite[0][0] = 1'b0;
    force dut.snitch_data_qamo[0][0] = '0;
    force dut.snitch_data_qdata[0][0] = '0;
    force dut.snitch_data_qstrb[0][0] = '1;
    force dut.snitch_data_qid[0][0] = '0;
    force dut.snitch_data_qburst_len[0][0] = BurstLenWidth'(1);
    #2;
    for (int unsigned group = 0; group < NumGroups; group++) begin
      for (int unsigned tile = 0; tile < NumTilesPerGroup; tile++) begin
        tile_id = (group * NumTilesPerGroup) + tile;
        // All formerly reserved SRAM words must decode as ordinary data.
        for (int unsigned word = GroupControlWord; word < 256; word++) begin
          check(word * BeWidth * NumBanks + group * BeWidth * NumBanksPerGroup +
                tile * BeWidth * NumBanksPerTile, 3'b010, 0);
          check(word * BeWidth * NumBanks + group * BeWidth * NumBanksPerGroup +
                ((tile+1) % NumTilesPerGroup) * BeWidth * NumBanksPerTile, 3'b001, 0);
          for (int unsigned op = 0; op < 4; op++)
            check(GroupControlBase + word * BeWidth * NumBanks +
                  group * BeWidth * NumBanksPerGroup + tile * BeWidth * NumBanksPerTile +
                  op * BeWidth, GroupControlEnable ? 3'b001 : 3'b100, GroupControlEnable);
        end
        check(GroupControlStart - 4, 3'b100, 0);
        check(GroupControlStart + NumCoresPerGroup * BeWidth * NumBanks, 3'b100, 0);
        check(GroupControlBase, 3'b100, 0);
        check(GroupControlStart + ((group+1) % NumGroups) * BeWidth * NumBanksPerGroup,
              3'b100, 0);
        check(32'h8000_0000, 3'b100, 0);
        check(32'h4000_0000, 3'b100, 0);
      end
    end
    $display("PASS group-control decoder: groups=%0d checks=%0d", NumGroups, checks);
    $finish;
  end
endmodule
