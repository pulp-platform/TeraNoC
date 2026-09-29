// ============================================================================
// tb_x_detect.svh — report where unknown (X/Z) values enter the system. Include inside mempool_tb.
// Enabled only with +define+XDET (compile time); prints nothing otherwise.
//
//   [XDET] L1   an L1 bank read returned a word with any X/Z bit: cycle, group, tile, bank, the
//               reconstructed byte address, the requesting initiator and the data (x shown).
//               Checked one cycle after the bank's read request (tc_sram latency 1). Note a
//               halfword read whose OTHER half was never written reports too -- read the data.
//   [XDET] L1W  an L1 bank write whose ENABLED bytes carry X/Z (printed from XDET_L1_FROM on,
//               like the reads): who wrote the unknown value, and where.
//   [XDET] L2   an L2 bank read returned X/Z (raw bank output, before any SIM_XZERO_L2 masking).
//   [XDET] VRFW / VRFR   a Spatz vector-register write (enabled bytes) / read carrying X, per port
//               (W: 0 VFU, 1 VLSU, 2 VSLDU; R: 0-2 VFU vs2/vs1/vd, 3-4 VLSU vs2/vd, 5 VSLDU)
//   [XDET] MRSP a Spatz VLSU memory response word carrying X (the core's side of the memory path)
//   [XDET] NET  X in a remote response word at SOUT (source tile), MRSP (NoC -> MSHR) or MRO
//               (MSHR -> tile): with the bank check above, this places where an X is BORN.
//   All of these print from XDET_L1_FROM on (the warm-up computes on never-written memory).
//   [XDET] PC   a core's program counter became X/Z (printed once per core): a branch or jump on
//               an unknown value, i.e. the core can no longer make progress.
// Each class prints its first XDET_MAX events (default 20) and then a running count every
// 100k cycles while new events keep arriving. L1 events before cycle XDET_L1_FROM (define, or
// plusarg +XDET_L1_FROM=<cyc>; default 0) are counted but not printed, so a late event is not
// hidden behind a warm-up flood. The PC line also names the last known (non-X) PC.
// ============================================================================

`ifndef TB_X_DETECT_SVH
`define TB_X_DETECT_SVH

// pragma translate_off
`ifndef VERILATOR
`ifdef XDET

`ifndef XDET_MAX
`define XDET_MAX 40
`endif
`ifndef XDET_L1_FROM
`define XDET_L1_FROM 0
`endif

`define XD_TILE(G,T) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group.i_mempool_group.gen_tiles[T].i_tile

  int unsigned xd_cyc, xd_l1_n, xd_l1_late_n, xd_l1w_n, xd_vw_n, xd_vr_n, xd_mr_n, xd_net_n, xd_l2_n, xd_pc_n, xd_last_report, xd_l1_from;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xd_cyc = 0; xd_last_report = 0;
    end else begin
      xd_cyc = xd_cyc + 1;
      if (xd_cyc - xd_last_report >= 100000 && (xd_l1_n + xd_l2_n + xd_pc_n) > 0) begin
        $display("[XDET] cyc=%0d totals: L1=%0d (from cyc %0d: %0d, writes %0d) L2=%0d PC=%0d VRFW=%0d VRFR=%0d MRSP=%0d NET=%0d",
                 xd_cyc, xd_l1_n, xd_l1_from, xd_l1_late_n, xd_l1w_n, xd_l2_n, xd_pc_n,
                 xd_vw_n, xd_vr_n, xd_mr_n, xd_net_n);
        xd_last_report = xd_cyc;
      end
    end
  end
  initial begin
    xd_l1_n = 0; xd_l1_late_n = 0; xd_l1w_n = 0; xd_vw_n = 0; xd_vr_n = 0; xd_mr_n = 0; xd_net_n = 0; xd_l2_n = 0; xd_pc_n = 0;
    if (!$value$plusargs("XDET_L1_FROM=%d", xd_l1_from)) xd_l1_from = `XDET_L1_FROM;
  end

  // ---- L1 banks ----
  for (genvar g = 0; g < NumGroups; g++) begin : gen_xd_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_xd_t
      for (genvar b = 0; b < NumBanksPerTile; b++) begin : gen_xd_b
        logic        rd_q;
        logic [31:0] row_q;
        logic [31:0] ini_q;
        logic        wx;
        initial wx = 1'b0;
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            rd_q <= 1'b0;
          end else begin
            if (rd_q && $isunknown(`XD_TILE(g,t).gen_banks[b].resp_rdata)) begin
              xd_l1_n = xd_l1_n + 1;
              if (xd_cyc >= xd_l1_from) xd_l1_late_n = xd_l1_late_n + 1;
              if (xd_cyc >= xd_l1_from && xd_l1_late_n <= `XDET_MAX)
                $display("[XDET] L1 cyc=%0d g=%0d t=%0d bank=%0d addr=0x%08h ini=0x%0h data=%h",
                         xd_cyc, g, t, b,
                         ((((row_q * NumGroups + g) * NumTilesPerGroup + t) * NumBanksPerTile + b) * 4),
                         ini_q, `XD_TILE(g,t).gen_banks[b].resp_rdata);
            end
            if (xd_cyc >= xd_l1_from && `XD_TILE(g,t).gen_banks[b].req_valid &&
                `XD_TILE(g,t).gen_banks[b].req_write) begin
              for (int unsigned y = 0; y < 4; y++)
                if (`XD_TILE(g,t).gen_banks[b].req_be[y] &&
                    $isunknown(`XD_TILE(g,t).gen_banks[b].req_wdata[8*y +: 8])) wx = 1'b1;
              if (wx) begin
                xd_l1w_n = xd_l1w_n + 1;
                if (xd_l1w_n <= `XDET_MAX)
                  $display("[XDET] L1W cyc=%0d g=%0d t=%0d bank=%0d addr=0x%08h ini=0x%0h be=%b data=%h",
                           xd_cyc, g, t, b,
                           ((((32'(`XD_TILE(g,t).gen_banks[b].req_addr) * NumGroups + g) * NumTilesPerGroup + t)
                             * NumBanksPerTile + b) * 4),
                           32'(`XD_TILE(g,t).gen_banks[b].meta_in.ini_addr),
                           `XD_TILE(g,t).gen_banks[b].req_be, `XD_TILE(g,t).gen_banks[b].req_wdata);
              end
              wx = 1'b0;
            end
            rd_q  <= `XD_TILE(g,t).gen_banks[b].req_valid && !`XD_TILE(g,t).gen_banks[b].req_write;
            row_q <= 32'(`XD_TILE(g,t).gen_banks[b].req_addr);
            ini_q <= 32'(`XD_TILE(g,t).gen_banks[b].meta_in.ini_addr);
          end
        end
      end
    end
  end

  // ---- L2 banks (raw bank output, before SIM_XZERO_L2) ----
  for (genvar i = 0; i < NumL2Banks; i++) begin : gen_xd_l2
    logic [31:0] row_q;
    always @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        row_q <= '0;
      end else begin
        if (dut.bank_rvalid[i] && $isunknown(dut.bank_rdata[i])) begin
          xd_l2_n = xd_l2_n + 1;
          if (xd_l2_n <= `XDET_MAX)
            $display("[XDET] L2 cyc=%0d bank=%0d row=0x%0h", xd_cyc, i, row_q);
        end
        if (dut.bank_req[i] && !dut.bank_we[i]) row_q <= 32'(dut.bank_addr[i]);
      end
    end
  end

  // ---- core program counters ----
  for (genvar g = 0; g < NumGroups; g++) begin : gen_xd_pc_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_xd_pc_t
      for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_xd_pc_c
        logic        seen;
        logic [31:0] pc_ok;  // last PC without X
        always @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            seen  <= 1'b0;
            pc_ok <= '0;
          end else if (!$isunknown(`XD_TILE(g,t).gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.pc_q)) begin
            pc_ok <= `XD_TILE(g,t).gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.pc_q;
          end else if (!seen) begin
            seen <= 1'b1;
            xd_pc_n = xd_pc_n + 1;
            if (xd_pc_n <= `XDET_MAX)
              $display("[XDET] PC cyc=%0d hart=0x%0h (g=%0d t=%0d c=%0d) pc=%h last_pc=%h", xd_cyc,
                       (g * NumTilesPerGroup + t) * NumCoresPerTile + c, g, t, c,
                       `XD_TILE(g,t).gen_cores[c].gen_mempool_cc.riscv_core.i_snitch.pc_q, pc_ok);
          end
        end
      end
    end
  end

  // ---- Spatz: vector register file and VLSU memory responses ----
`define XD_SPATZ(G,T,C) `XD_TILE(G,T).gen_cores[C].gen_mempool_cc.riscv_core
  for (genvar g = 0; g < NumGroups; g++) begin : gen_xd_sp_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_xd_sp_t
      for (genvar c = 0; c < NumCoresPerTile; c++) begin : gen_xd_sp_c
        localparam int unsigned H = (g * NumTilesPerGroup + t) * NumCoresPerTile + c;
        always @(posedge clk) begin
          if (rst_n && xd_cyc >= xd_l1_from) begin
            for (int w = 0; w < $size(`XD_SPATZ(g,t,c).i_spatz.vrf_we); w++)
              if (`XD_SPATZ(g,t,c).i_spatz.vrf_we[w] && `XD_SPATZ(g,t,c).i_spatz.vrf_wvalid[w]) begin
                automatic logic x = 1'b0;
                for (int y = 0; y < $bits(`XD_SPATZ(g,t,c).i_spatz.vrf_wbe[w]); y++)
                  if (`XD_SPATZ(g,t,c).i_spatz.vrf_wbe[w][y] &&
                      $isunknown(`XD_SPATZ(g,t,c).i_spatz.vrf_wdata[w][8*y +: 8])) x = 1'b1;
                if (x) begin
                  xd_vw_n = xd_vw_n + 1;
                  if (xd_vw_n <= `XDET_MAX)
                    $display("[XDET] VRFW cyc=%0d hart=0x%0h port=%0d waddr=0x%0h wbe=%b data=%h", xd_cyc, H, w,
                             `XD_SPATZ(g,t,c).i_spatz.vrf_waddr[w], `XD_SPATZ(g,t,c).i_spatz.vrf_wbe[w],
                             `XD_SPATZ(g,t,c).i_spatz.vrf_wdata[w]);
                end
              end
            for (int r = 0; r < $size(`XD_SPATZ(g,t,c).i_spatz.vrf_re); r++)
              if (`XD_SPATZ(g,t,c).i_spatz.vrf_rvalid[r] &&
                  $isunknown(`XD_SPATZ(g,t,c).i_spatz.vrf_rdata[r])) begin
                xd_vr_n = xd_vr_n + 1;
                if (xd_vr_n <= `XDET_MAX)
                  $display("[XDET] VRFR cyc=%0d hart=0x%0h port=%0d raddr=0x%0h data=%h", xd_cyc, H, r,
                           `XD_SPATZ(g,t,c).i_spatz.vrf_raddr[r], `XD_SPATZ(g,t,c).i_spatz.vrf_rdata[r]);
              end
            for (int p = 0; p < NumMemPortsPerSpatz; p++)
              if (`XD_SPATZ(g,t,c).spatz_mem_rsp_valid[p] && !`XD_SPATZ(g,t,c).spatz_mem_rsp[p].write &&
                  $isunknown(`XD_SPATZ(g,t,c).spatz_mem_rsp[p].data)) begin
                xd_mr_n = xd_mr_n + 1;
                if (xd_mr_n <= `XDET_MAX)
                  $display("[XDET] MRSP cyc=%0d hart=0x%0h port=%0d id=0x%0h data=%h", xd_cyc, H, p,
                           `XD_SPATZ(g,t,c).spatz_mem_rsp[p].id, `XD_SPATZ(g,t,c).spatz_mem_rsp[p].data);
              end
          end
        end
      end
    end
  end
`undef XD_SPATZ

  // ---- remote response words: source tile, NoC -> MSHR, MSHR -> tile ----
`define XD_GRP(G) dut.i_mempool_cluster.gen_groups_x[(G)/NumY].gen_groups_y[(G)%NumY].gen_rtl_group.i_group
  for (genvar g = 0; g < NumGroups; g++) begin : gen_xd_net_g
    for (genvar t = 0; t < NumTilesPerGroup; t++) begin : gen_xd_net_t
      for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_xd_net_p
        always @(posedge clk) begin
          if (rst_n && xd_cyc >= xd_l1_from) begin
            if (`XD_GRP(g).tcdm_slave_resp_valid[t][p] && `XD_GRP(g).tcdm_slave_resp_ready[t][p] &&
                $isunknown(`XD_GRP(g).tcdm_slave_resp[t][p].rdata.data)) begin
              xd_net_n = xd_net_n + 1;
              if (xd_net_n <= `XDET_MAX)
                $display("[XDET] NET SOUT cyc=%0d g=%0d t=%0d p=%0d to_g=%0d ini=%0d core=%0d meta=0x%0h wen=%0d",
                         xd_cyc, g, t, p, `XD_GRP(g).tcdm_slave_resp[t][p].src_group_id,
                         `XD_GRP(g).tcdm_slave_resp[t][p].ini_addr,
                         `XD_GRP(g).tcdm_slave_resp[t][p].rdata.core_id,
                         `XD_GRP(g).tcdm_slave_resp[t][p].rdata.meta_id,
                         `XD_GRP(g).tcdm_slave_resp[t][p].wen);
            end
            if (`XD_GRP(g).tcdm_master_resp_valid[t][p] && `XD_GRP(g).tcdm_master_resp_ready[t][p] &&
                $isunknown(`XD_GRP(g).tcdm_master_resp[t][p].rdata.data)) begin
              xd_net_n = xd_net_n + 1;
              if (xd_net_n <= `XDET_MAX)
                $display("[XDET] NET MRSP cyc=%0d g=%0d lane=%0d p=%0d tile=%0d core=%0d meta=0x%0h tag=0x%0h wen=%0d",
                         xd_cyc, g, t, p, `XD_GRP(g).tcdm_master_resp[t][p].tile_id,
                         `XD_GRP(g).tcdm_master_resp[t][p].rdata.core_id,
                         `XD_GRP(g).tcdm_master_resp[t][p].rdata.meta_id,
                         `XD_GRP(g).tcdm_master_resp[t][p].mshr_tag,
                         `XD_GRP(g).tcdm_master_resp[t][p].wen);
            end
          end
        end
      end
    end
    if (MshrSplit) begin : gen_xd_mro
      for (genvar m = 0; m < MshrNumSlices; m++) begin : gen_xd_m
        for (genvar l = 0; l < MshrSliceTiles; l++) begin : gen_xd_l
          for (genvar p = 1; p < NumRemoteRespPortsPerTile; p++) begin : gen_xd_p
            always @(posedge clk) begin
              if (rst_n && xd_cyc >= xd_l1_from &&
                  `XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.group_mshr_resp_valid_o[l][p] &&
                  `XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.group_mshr_resp_ready_i[l][p] &&
                  $isunknown(`XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.group_mshr_resp_o[l][p].rdata.data)) begin
                xd_net_n = xd_net_n + 1;
                if (xd_net_n <= `XDET_MAX)
                  $display("[XDET] NET MRO cyc=%0d g=%0d slice=%0d lane=%0d p=%0d core=%0d meta=0x%0h from_mshr=%0d bypass=%0d",
                           xd_cyc, g, m, l, p,
                           `XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.group_mshr_resp_o[l][p].rdata.core_id,
                           `XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.group_mshr_resp_o[l][p].rdata.meta_id,
                           `XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.resp_from_mshr[l][p],
                           `XD_GRP(g).i_mempool_group.gen_group_mshr_split.gen_slice[m].i_slice.i_core.resp_from_bypass[l][p]);
              end
            end
          end
        end
      end
    end
  end
`undef XD_GRP

`undef XD_TILE

`endif
`endif
// pragma translate_on

`endif
