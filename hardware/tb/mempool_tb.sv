// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

import "DPI-C" function void read_elf (input string filename);
import "DPI-C" function byte get_section (output longint address, output longint len);
import "DPI-C" context function byte read_section(input longint address, inout byte buffer[]);
import "DPI-C" function longint get_symbol_addr(input string name);
import "DPI-C" context function int mempool_dpi_check(
  input int check_type,
  input int count,
  input int tolerance,
  input int verbose,
  inout byte result_buffer[],
  inout byte golden_buffer[]
);

`define wait_for(signal) \
  do \
    @(posedge clk); \
  while (!signal);

module mempool_tb;

  /*****************
   *  Definitions  *
   *****************/

  timeunit      1ns;
  timeprecision 1ps;

  import mempool_pkg::*;
  import floo_pkg::*;
  import axi_pkg::xbar_cfg_t;
  import axi_pkg::xbar_rule_32_t;
  import cf_math_pkg::idx_width;

  `ifdef BOOT_ADDR
  localparam BootAddr = `BOOT_ADDR;
  `else
  localparam BootAddr = 0;
  `endif

  localparam ClockPeriod = 2ns;
  localparam TA          = 0.2ns;
  localparam TT          = 0.8ns;

  localparam PollEoc     = 0;
  localparam int unsigned DpiCheckMax      = 32;
  localparam int unsigned DpiCheckDescSize = 24;

 /********************************
   *  Clock and Reset Generation  *
   ********************************/

  logic clk;
  logic rst_n;

  // Toggling the clock
  always #(ClockPeriod/2) clk = !clk;

  // Controlling the reset
  initial begin
    clk   = 1'b1;
    rst_n = 1'b0;

    repeat (5)
      #(ClockPeriod);

    rst_n = 1'b1;
  end

  // Passing the clock and reset to the DRAM simulation engine
  `ifdef DRAM
    dram_sim_engine #(.ClkPeriodNs(ClockPeriod)) i_dram_sim_engine (.clk_i(clk), .rst_ni(rst_n));
  `endif

  /*********
   *  AXI  *
   *********/

  `include "axi/assign.svh"

  localparam NumAXIMasters = 1;
  localparam NumAXISlaves  = 2;
  localparam NumRules  = NumAXISlaves-1;

  typedef enum logic [$clog2(NumAXISlaves)-1:0] {
    UART,
    Host
  } axi_slave_target;

  axi_system_req_t    [NumAXIMasters - 1:0] axi_mst_req;
  axi_system_resp_t   [NumAXIMasters - 1:0] axi_mst_resp;
  axi_tb_req_t        [NumAXISlaves  - 1:0] axi_mem_req;
  axi_tb_resp_t       [NumAXISlaves  - 1:0] axi_mem_resp;

  axi_system_req_t                          to_mempool_req;
  axi_system_resp_t                         to_mempool_resp;

  localparam xbar_cfg_t XBarCfg = '{
    NoSlvPorts        : NumAXIMasters,
    NoMstPorts        : NumAXISlaves,
    MaxMstTrans       : 4,
    MaxSlvTrans       : 4,
    FallThrough       : 1'b0,
    LatencyMode       : axi_pkg::CUT_MST_PORTS,
    PipelineStages    : 0,
    AxiIdWidthSlvPorts: AxiSystemIdWidth,
    AxiIdUsedSlvPorts : AxiSystemIdWidth,
    UniqueIds         : 0,
    AxiAddrWidth      : AddrWidth,
    AxiDataWidth      : DataWidth,
    NoAddrRules       : NumRules
  };

  /*********
   *  DUT  *
   *********/

  logic fetch_en;
  logic eoc_valid;

  mempool_system #(
    .TCDMBaseAddr   (32'h0          ),
    .BootAddr       (BootAddr       )
  ) dut (
    .clk_i          (clk            ),
    .rst_ni         (rst_n          ),
    .fetch_en_i     (fetch_en       ),
    .eoc_valid_o    (eoc_valid      ),
    .busy_o         (/*Unused*/     ),
    .mst_req_o      (axi_mst_req    ),
    .mst_resp_i     (axi_mst_resp   ),
    .slv_req_i      (to_mempool_req ),
    .slv_resp_o     (to_mempool_resp)
  );

  /**********************
   *  AXI Interconnect  *
   **********************/

  localparam addr_t UARTBaseAddr = 32'hC000_0000;
  localparam addr_t UARTEndAddr = 32'hC000_FFFF;

  xbar_rule_32_t [NumRules-1:0] xbar_routing_rules = '{
    '{idx: UART, start_addr: UARTBaseAddr, end_addr: UARTEndAddr}
  };

  axi_xbar #(
    .Cfg          (XBarCfg          ),
    .slv_aw_chan_t(axi_system_aw_t  ),
    .mst_aw_chan_t(axi_tb_aw_t      ),
    .w_chan_t     (axi_tb_w_t       ),
    .slv_b_chan_t (axi_system_b_t   ),
    .mst_b_chan_t (axi_tb_b_t       ),
    .slv_ar_chan_t(axi_system_ar_t  ),
    .mst_ar_chan_t(axi_tb_ar_t      ),
    .slv_r_chan_t (axi_system_r_t   ),
    .mst_r_chan_t (axi_tb_r_t       ),
    .slv_req_t    (axi_system_req_t ),
    .slv_resp_t   (axi_system_resp_t),
    .mst_req_t    (axi_tb_req_t     ),
    .mst_resp_t   (axi_tb_resp_t    ),
    .rule_t       (xbar_rule_32_t)
  ) i_testbench_xbar (
    .clk_i                (clk                  ),
    .rst_ni               (rst_n                ),
    .test_i               (1'b0                 ),
    .slv_ports_req_i      (axi_mst_req          ),
    .slv_ports_resp_o     (axi_mst_resp         ),
    .mst_ports_req_o      (axi_mem_req          ),
    .mst_ports_resp_i     (axi_mem_resp         ),
    .addr_map_i           (xbar_routing_rules   ),
    .en_default_mst_port_i('1                   ), // default all slave ports to master port Host
    .default_mst_port_i   ({NumAXIMasters{Host}})
  );

  /**********
   *  HOST  *
   **********/
  assign axi_mem_resp[Host] = '0;

  /**********
   *  UART  *
   **********/

  axi_uart #(
    .axi_req_t (axi_tb_req_t ),
    .axi_resp_t(axi_tb_resp_t)
  ) i_axi_uart (
    .clk_i     (clk               ),
    .rst_ni    (rst_n             ),
    .testmode_i(1'b0              ),
    .axi_req_i (axi_mem_req[UART] ),
    .axi_resp_o(axi_mem_resp[UART])
  );

  /*********
   *  WFI  *
   *********/

`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR
`ifndef POSTLAYOUT
`ifndef TRAFFIC_GEN

  // Helper debug signal with the wfi of each core
  logic [NumCores-1:0] wfi;
  for (genvar g = 0; g < NumGroups; g++) begin: gen_wfi_groups
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin: gen_wfi_tiles
      for (genvar c = 0; c < NumCoresPerTile; c++) begin: gen_wfi_cores
        assign wfi[g*NumTilesPerGroup*NumCoresPerTile + t*NumCoresPerTile + c] = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.wfi_q;
      end: gen_wfi_cores
    end: gen_wfi_tiles
  end: gen_wfi_groups

`endif
`endif
`endif
`endif

  /************************
   *  Write/Read via AXI  *
   ************************/

  task write_to_mempool(input addr_t addr, input data_t data, output axi_pkg::resp_t resp);
    to_mempool_req.aw.id = 'h18d;
    to_mempool_req.aw.addr = addr;
    to_mempool_req.aw.size = 'h2;
    to_mempool_req.aw.burst = axi_pkg::BURST_INCR;
    to_mempool_req.aw_valid = 1'b1;
    `wait_for(to_mempool_resp.aw_ready)
    to_mempool_req.aw_valid = 1'b0;
    to_mempool_req.w.data = data << addr[ByteOffset +: $clog2(AxiDataWidth/DataWidth)] * DataWidth;
    to_mempool_req.w.strb = {BeWidth{1'b1}} << addr[ByteOffset +: $clog2(AxiDataWidth/DataWidth)] * BeWidth;
    to_mempool_req.w.last = 1'b1;
    to_mempool_req.w.user = '0;
    to_mempool_req.w_valid = 1'b1;
    `wait_for(to_mempool_resp.w_ready)
    to_mempool_req.w_valid = 1'b0;
    to_mempool_req.b_ready = 1'b1;
    `wait_for(to_mempool_resp.b_valid)
    resp = to_mempool_resp.b.resp;
    to_mempool_req.b_ready = 1'b0;
  endtask

  task read_from_mempool(input addr_t addr, output data_t data, output axi_pkg::resp_t resp);
    to_mempool_req.ar.id = 'h18d;
    to_mempool_req.ar.addr = addr;
    to_mempool_req.ar.size = 'h2;
    to_mempool_req.ar.burst = axi_pkg::BURST_INCR;
    to_mempool_req.ar_valid = 1'b1;
    `wait_for(to_mempool_resp.ar_ready)
    to_mempool_req.ar_valid = 1'b0;
    to_mempool_req.r_ready = 1'b1;
    `wait_for(to_mempool_resp.r_valid)
    data = to_mempool_resp.r.data >> addr[ByteOffset +: $clog2(AxiDataWidth/DataWidth)] * DataWidth;
    resp = to_mempool_resp.r.resp;
    to_mempool_req.r_ready = 1'b0;
    $display("[TB] Read %08x from %08x at %t (resp=%d).", data, addr, $time, resp);
  endtask

  axi_pkg::resp_t resp;

`ifndef DRAM
  logic [L2BankAddrWidth-1:0] dpi_l2_sram_addr [NumL2Banks];
  logic [L2BankWidth-1:0] dpi_l2_sram_rdata [NumL2Banks];

  // VCS reports XMRE on dut.gen_l2_banks[bank_id] with a runtime index.
  for (genvar bank = 0; bank < NumL2Banks; bank++) begin : gen_dpi_l2_sram_read
    assign dpi_l2_sram_rdata[bank] =
        dut.gen_l2_banks[bank].l2_mem.sram[dpi_l2_sram_addr[bank]];
  end
`else
  logic [AddrWidth-1:0] dpi_l2_dram_addr [NumDrams];
  logic [7:0] dpi_l2_dram_rdata [NumDrams];

  // VCS reports XMRE on dut.gen_drams[bank_id] with a runtime index.
  for (genvar bank = 0; bank < NumDrams; bank++) begin : gen_dpi_l2_dram_read
    always_comb begin
      dut.gen_drams[bank].i_axi_dram_sim.i_sim_dram.check_a_byte_in_dram(
          longint'(dpi_l2_dram_addr[bank]), dpi_l2_dram_rdata[bank]);
    end
  end
`endif

  function automatic int unsigned dpi_check_load_u32(input byte buffer[],
                                                     input int unsigned offset);
    return {buffer[offset + 3], buffer[offset + 2], buffer[offset + 1], buffer[offset]};
  endfunction

  function automatic int unsigned dpi_check_elem_size(input int unsigned check_type);
    case (check_type)
      1, 4: return 1;
      2, 5: return 2;
      3, 6: return 4;
      default: return 0;
    endcase
  endfunction

  task automatic read_dpi_check_l2_bytes(input addr_t addr, input int unsigned length,
                                         ref byte buffer[]);
    addr_t byte_addr;
    addr_t end_addr;
    addr_t rel_addr;
`ifndef DRAM
    int cached_bank;
    logic [L2BankAddrWidth-1:0] cached_addr;
    logic [L2BankWidth-1:0] cached_row;
    bit have_row;
`endif

    if (length == 0) begin
      return;
    end
    end_addr = addr + addr_t'(length);
    if ((addr < dut.L2MemoryBaseAddr) || (end_addr < addr) ||
        (end_addr > dut.L2MemoryEndAddr)) begin
      $fatal(1, "[DPI_CHECK] L2 read range %08x..%08x is outside L2",
             addr, end_addr);
    end

`ifndef DRAM
    have_row = 1'b0;
    cached_bank = -1;
    for (int unsigned i = 0; i < length; i++) begin
      automatic int bank_id;
      automatic int byte_offset;
      automatic sram_ctrl_interleave_t sram_ctrl_info;

      byte_addr = addr + addr_t'(i);
      rel_addr = byte_addr - dut.L2MemoryBaseAddr;
      sram_ctrl_info = getSramCTRLInfo(rel_addr);
      bank_id = sram_ctrl_info.sram_ctrl_id;
      if ((bank_id < 0) || (bank_id >= NumL2Banks)) begin
        $fatal(1, "[DPI_CHECK] SRAM bank index %0d is out of range for address %08x",
               bank_id, byte_addr);
      end

      if (!have_row || (bank_id != cached_bank) ||
          (sram_ctrl_info.sram_ctrl_addr[L2BankAddrWidth-1:0] != cached_addr)) begin
        cached_bank = bank_id;
        cached_addr = sram_ctrl_info.sram_ctrl_addr[L2BankAddrWidth-1:0];
        dpi_l2_sram_addr[bank_id] = cached_addr;
        #0;
        cached_row = dpi_l2_sram_rdata[bank_id];
        have_row = 1'b1;
      end

      byte_offset = rel_addr[L2BankByteOffset-1:0];
      buffer[i] = cached_row[8 * byte_offset +: 8];
    end
`else
    for (int unsigned i = 0; i < length; i++) begin
      automatic int bank_id;
      automatic dram_ctrl_interleave_t dram_ctrl_info;

      byte_addr = addr + addr_t'(i);
      rel_addr = byte_addr - dut.L2MemoryBaseAddr;
      dram_ctrl_info = getDramCTRLInfo(rel_addr);
      bank_id = dram_ctrl_info.dram_ctrl_id;
      if ((bank_id < 0) || (bank_id >= NumDrams)) begin
        $fatal(1, "[DPI_CHECK] DRAM bank index %0d is out of range for address %08x",
               bank_id, byte_addr);
      end
      dpi_l2_dram_addr[bank_id] = dram_ctrl_info.dram_ctrl_addr;
      #0;
      buffer[i] = byte'(dpi_l2_dram_rdata[bank_id]);
    end
`endif
  endtask

  task automatic run_dpi_checks();
    longint count_addr_long;
    longint table_addr_long;
    addr_t count_addr;
    addr_t table_addr;
    byte count_buffer[];
    byte desc_buffer[];
    int unsigned check_count;
    int unsigned total_checks;
    int unsigned total_errors;

    count_addr_long = get_symbol_addr("mempool_dpi_check_count");
    table_addr_long = get_symbol_addr("mempool_dpi_checks");
    if ((count_addr_long == 0) || (table_addr_long == 0)) begin
      return;
    end

    count_addr = addr_t'(count_addr_long);
    table_addr = addr_t'(table_addr_long);
    count_buffer = new[4];
    read_dpi_check_l2_bytes(count_addr, 4, count_buffer);
    check_count = dpi_check_load_u32(count_buffer, 0);

    if (check_count == 0) begin
      return;
    end
    if (check_count > DpiCheckMax) begin
      $fatal(1, "[DPI_CHECK] Descriptor count %0d exceeds max %0d", check_count, DpiCheckMax);
    end

    desc_buffer = new[DpiCheckDescSize];
    total_checks = 0;
    total_errors = 0;
    for (int unsigned i = 0; i < check_count; i++) begin
      int unsigned check_type;
      int unsigned elem_size;
      int unsigned elements;
      int unsigned tolerance;
      int unsigned verbose;
      int unsigned nbytes;
      addr_t result_addr;
      addr_t golden_addr;
      byte result_buffer[];
      byte golden_buffer[];
      int errors;

      read_dpi_check_l2_bytes(table_addr + i * DpiCheckDescSize, DpiCheckDescSize,
                              desc_buffer);
      check_type = dpi_check_load_u32(desc_buffer, 0);
      elements = dpi_check_load_u32(desc_buffer, 4);
      tolerance = dpi_check_load_u32(desc_buffer, 8);
      result_addr = addr_t'(dpi_check_load_u32(desc_buffer, 12));
      golden_addr = addr_t'(dpi_check_load_u32(desc_buffer, 16));
      verbose = dpi_check_load_u32(desc_buffer, 20);

      elem_size = dpi_check_elem_size(check_type);
      if (elem_size == 0) begin
        $fatal(1, "[DPI_CHECK] Descriptor %0d has unsupported type %0d",
               i, check_type);
      end

      nbytes = elements * elem_size;
      result_buffer = new[nbytes];
      golden_buffer = new[nbytes];
      read_dpi_check_l2_bytes(result_addr, nbytes, result_buffer);
      read_dpi_check_l2_bytes(golden_addr, nbytes, golden_buffer);

      errors = mempool_dpi_check(int'(check_type), int'(elements), int'(tolerance),
                                 int'(verbose), result_buffer, golden_buffer);
      if (errors < 0) begin
        $fatal(1, "[DPI_CHECK] Comparator returned negative error count %0d", errors);
      end
      $display("[DPI_CHECK] Check %0d: %0d ERRORS out of %0d CHECKS",
               i, errors, elements);
      total_errors += errors;
      total_checks += elements;
    end

    $display("[DPI_CHECK] %0d ERRORS out of %0d CHECKS", total_errors, total_checks);
    if (total_errors != 0) begin
      $fatal(1, "[DPI_CHECK] Result verification failed");
    end
  endtask

  // Simulation control
  initial begin
    localparam ctrl_phys_addr = 32'h4000_0000;
    localparam ctrl_size      = 32'h0100_0000;
    localparam l2_phys_addr   = 32'h8000_0000;
    localparam l2_size        = 32'h0700_0000;
    localparam ctrl_virt_addr = ctrl_phys_addr;
    localparam l2_virt_addr   = l2_phys_addr;
    addr_t first, last, phys_addr;
    data_t rdata;
    axi_pkg::resp_t resp;
    fetch_en = 1'b0;
    to_mempool_req = '{default: '0};
    to_mempool_req.aw.burst = axi_pkg::BURST_INCR;
    to_mempool_req.ar.burst = axi_pkg::BURST_INCR;
    to_mempool_req.aw.cache = axi_pkg::CACHE_MODIFIABLE;
    to_mempool_req.ar.cache = axi_pkg::CACHE_MODIFIABLE;
    // Wait for reset.
    wait (rst_n);
    @(posedge clk);

    // Give the cores time to execute the bootrom's program
    #(1000*ClockPeriod);

    // Wake up all cores
    write_to_mempool(ctrl_virt_addr + 32'h4, {DataWidth{1'b1}}, resp);
    assert(resp == axi_pkg::RESP_OKAY);

    if (PollEoc) begin
      // Poll for EOC (as done on the host at the moment)
      do begin
        #(1000*ClockPeriod);
        @(posedge clk);
        read_from_mempool(ctrl_virt_addr, rdata, resp);
        assert(resp == axi_pkg::RESP_OKAY);
      end while (rdata == 0);
    end else begin
      // Wait for the interrupt
      wait (eoc_valid);
      read_from_mempool(ctrl_virt_addr, rdata, resp);
      assert(resp == axi_pkg::RESP_OKAY);
    end
    run_dpi_checks();
    $timeformat(-9, 2, " ns", 0);
    $display("[EOC] Simulation ended at %t (retval = %0d).", $time, rdata >> 1);
    $finish(0);
    // Start MemPool
    fetch_en = 1'b1;
  end

  /***********************
   *  L2 Initialization  *
   ***********************/

`ifndef DRAM
  for (genvar bank = 0; bank < NumL2Banks; bank++) begin : gen_srams_init
    initial begin : l2_init
      automatic logic [L2BankWidth-1:0] mem_row;
      byte buffer [];
      addr_t address;
      addr_t length;
      string binary;
      // Initialize memories
      void'($value$plusargs("PRELOAD=%s", binary));
      if (binary != "") begin
        // Read ELF
        read_elf(binary);
        $display("Loading %s", binary);
        while (get_section(address, length)) begin
          // Read sections
          automatic int nwords = (length + L2BeWidth - 1)/L2BeWidth;
          $display("Loading section %x of length %x", address, length);
          buffer = new[nwords * L2BeWidth];
          void'(read_section(address, buffer));
          if (address >= dut.L2MemoryBaseAddr && address < dut.L2MemoryEndAddr) begin
            for (int i = 0; i < nwords * L2BeWidth; i += L2BankBeWidth) begin //per L2 words
              automatic sram_ctrl_interleave_t sram_ctrl_info;
              sram_ctrl_info = getSramCTRLInfo(address + i - dut.L2MemoryBaseAddr);
              if (sram_ctrl_info.sram_ctrl_id == bank) begin
                mem_row = '0;
                for (int b = 0; b < L2BankBeWidth; b++) begin
                  mem_row[8 * b +: 8] = buffer[i + b];
                end
                dut.gen_l2_banks[bank].l2_mem.init_val[sram_ctrl_info.sram_ctrl_addr] = mem_row;
              end
            end
          end else begin
            $display("Cannot initialize address %x, which doesn't fall into the L2 SRAM region.", address);
          end
        end
      end
    end : l2_init
  end : gen_srams_init

`else
  for (genvar bank = 0; bank < NumDrams; bank++) begin : gen_drams_init
    initial begin : l2_init
      byte buffer [];
      addr_t address;
      addr_t length;
      string binary;
      // Initialize memories
      void'($value$plusargs("PRELOAD=%s", binary));
      if (binary != "") begin
        // Read ELF
        read_elf(binary);
        $display("Loading %s", binary);
        while (get_section(address, length)) begin
          // Read sections
          automatic int nwords = (length + L2DramBeWidth - 1)/L2DramBeWidth;
          $display("Loading section %x of length %x", address, length);
          buffer = new[nwords * L2DramBeWidth];
          void'(read_section(address, buffer));
          if (address >= dut.L2MemoryBaseAddr) begin
            for (int i = 0; i < nwords * L2DramBeWidth; i++) begin //per byte
              automatic dram_ctrl_interleave_t dram_ctrl_info;
              dram_ctrl_info = getDramCTRLInfo(address + i - dut.L2MemoryBaseAddr);
              if (dram_ctrl_info.dram_ctrl_id == bank) begin
                dut.gen_drams[bank].i_axi_dram_sim.i_sim_dram.load_a_byte_to_dram(dram_ctrl_info.dram_ctrl_addr, buffer[i]);
              end
            end
          end else begin
            $display("Cannot initialize address %x, which doesn't fall into the L2 DRAM region.", address);
          end
        end
      end
    end : l2_init
  end : gen_drams_init
`endif

  /**************************************
   *  MAC Utilization                   *
   **************************************/
`ifndef TARGET_SYNTHESIS
`ifndef TARGET_VERILATOR
`ifndef POSTLAYOUT

`ifndef TRAFFIC_GEN

  // Cores
  logic [NumCores-1:0] instruction_handshake, lsu_request, lsu_handshake;
  int unsigned snitch_utilization, lsu_pressure, lsu_utilization;
  assign snitch_utilization = $countones(instruction_handshake);
  assign lsu_utilization = $countones(lsu_handshake);
  assign lsu_pressure = $countones(lsu_request);

  for (genvar g = 0; g < NumGroups; g++) begin
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin
      for (genvar c = 0; c < NumCoresPerTile; c++) begin
        logic valid_instr, stall;
        logic lsu_valid, lsu_ready;
        // Snitch
        assign valid_instr = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.valid_instr;
        assign stall = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.stall;
        assign instruction_handshake[g*NumTilesPerGroup*NumCoresPerTile+t*NumCoresPerTile+c] = valid_instr & !stall;
        // Interconnect
        assign lsu_valid = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.data_qvalid_o;
        assign lsu_ready = dut.i_mempool_cluster.gen_groups_x[g/NumY].gen_groups_y[g%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[t].i_tile.gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.data_qready_i;
        assign lsu_request[g*NumTilesPerGroup*NumCoresPerTile+t*NumCoresPerTile+c] = lsu_valid & !lsu_ready;
        assign lsu_handshake[g*NumTilesPerGroup*NumCoresPerTile+t*NumCoresPerTile+c] = lsu_valid & lsu_ready;
      end
    end
  end

`endif

  // AXI
  logic [NumGroups*NumAXIMastersPerGroup-1:0] w_valid, w_ready, r_ready, r_valid;
  int unsigned axi_w_utilization, axi_r_utilization;
  assign axi_w_utilization = $countones(w_valid & w_ready);
  assign axi_r_utilization = $countones(r_ready & r_valid);
  for (genvar a = 0; a < NumGroups*NumAXIMastersPerGroup; a++) begin
    assign w_valid[a] = dut.axi_mst_req[a].w_valid;
    assign w_ready[a] = dut.axi_mst_resp[a].w_ready;
    assign r_ready[a] = dut.axi_mst_req[a].r_ready;
    assign r_valid[a] = dut.axi_mst_resp[a].r_valid;
  end

`endif
`endif
`endif

/*****************
 * NoC Profiling *
 ****************/
`include "tb_noc_profiling.svh"
`include "tb_spm_profiling.svh"

/*******************
 * Spatz Profiling *
 ******************/
// Always-on vector-engine trace (gated only by Spatz presence, mempool_pkg::RVV);
// must follow tb_noc_profiling.svh, which declares the shared cycle_q counter.
`include "tb_spatz_profiling.svh"

endmodule : mempool_tb
