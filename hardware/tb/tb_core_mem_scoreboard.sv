// ============================================================================
// tb_core_mem_scoreboard.sv
//   Verification IP (VIP): per-port scoreboard at the core complex's
//   memory interface to the L1 TCDM interconnect.
//
//   Tracks every inflight request from each Snitch+Spatz core complex,
//   deallocates on response, warns on stuck requests, and dumps unresolved
//   entries at simulation end.
//
//   Hook point (via upward XMR): snitch_data_q* / snitch_data_p* inside
//   mempool_tile.sv — carries BOTH Snitch scalar LSU traffic AND Spatz
//   VLSU/FP-LSU traffic.
//
//   Non-synthesizable. Listed under target `mempool_vsim` in Bender.yml.
//   Instantiated once at the top of mempool_tb. Compile out by removing the
//   instance or with `+define+CMS_DISABLE`.
//
//   Style: although non-synthesizable, this VIP follows the repo RTL
//   conventions — `logic` (not `int`) for state/values and packed arrays
//   (not unpacked) for storage. `int` is used only for pure loop iterators
//   (matching the surrounding RTL idiom) and for the signed inflight delta.
//
//   Output line tags:
//     [CMS WARN]   - stuck request / orphan response / dup-id allocation
//     [CMS]        - periodic summary
//     [CMS FINAL]  - end-of-simulation dump
//
//   Compile-time controls (override with +define+NAME=value):
//     CMS_DISABLE          - compile-out the whole VIP
//     CMS_STUCK_THRESHOLD  - cycles after which a req is "stuck" (default 1000)
//     CMS_REPORT_PERIOD    - scan period in cycles            (default 1000)
//     CMS_GATE_BENCHMARK   - 1=count only during benchmark phase (default 0)
// ============================================================================

`ifndef CMS_STUCK_THRESHOLD
`define CMS_STUCK_THRESHOLD 1000
`endif

`ifndef CMS_REPORT_PERIOD
`define CMS_REPORT_PERIOD 1000
`endif

`ifndef CMS_GATE_BENCHMARK
`define CMS_GATE_BENCHMARK 0
`endif

// pragma translate_off
`ifndef VERILATOR
`ifndef CMS_DISABLE

module tb_core_mem_scoreboard (
  input logic clk_i,
  input logic rst_ni
);

  import mempool_pkg::*;
  import snitch_pkg::MetaIdWidth;

  // ---------------------------------------------------------------------------
  // Sizing
  // ---------------------------------------------------------------------------
  localparam int unsigned CMS_MaxId         = (1 << MetaIdWidth);
  localparam int unsigned CMS_NumLatBuckets = 6;  // <=16,<=64,<=256,<=1024,<=4096,>
  localparam int unsigned CmsCntW           = 32;  // event/counter width
  localparam int unsigned CmsCycW           = 64;  // cycle/latency width
  localparam int unsigned CmsBucketW        = $clog2(CMS_NumLatBuckets);

  // ---------------------------------------------------------------------------
  // Scoreboard entry type (packed struct, logic members)
  // ---------------------------------------------------------------------------
  typedef struct packed {
    logic                     valid;
    logic [CmsCycW-1:0]       cycle_issued;
    logic [31:0]              addr;
    logic                     is_write;
    logic [BurstLenWidth-1:0] burst_len;     // expected response beats
    logic [BurstLenWidth-1:0] beats_recv;    // beats received so far
    logic                     warned;        // already warned about this entry
  } cms_entry_t;

  // ---------------------------------------------------------------------------
  // State — packed arrays, visible in the waveform under /mempool_tb/u_cms/.
  // Dimension order [g][t][c][p](. . .)[width] matches the index order used
  // throughout, so cms_xxx[g][t][c][p] selects one port's value.
  // ---------------------------------------------------------------------------
  cms_entry_t [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CMS_MaxId-1:0] cms_tbl;

  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_req;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_resp_beats;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_resp_done;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_read;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_write;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_inflight;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_inflight_hw;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_orphan;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCntW-1:0] cms_n_dup_alloc;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCycW-1:0] cms_lat_sum;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CmsCycW-1:0] cms_lat_max;
  logic [NumGroups-1:0][NumTilesPerGroup-1:0][NumCoresPerTile-1:0][NumDataPortsPerCore-1:0][CMS_NumLatBuckets-1:0][CmsCntW-1:0] cms_lat_hist;

  logic [CmsCycW-1:0] cms_cycle;
  logic               cms_benchmark_active;

  // Benchmark gate (driven from the testbench's csr_trace_any_global via upward XMR)
  assign cms_benchmark_active = mempool_tb.csr_trace_any_global;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  function automatic logic [CmsBucketW-1:0] cms_lat_bucket(logic [CmsCycW-1:0] lat);
    if      (lat <= 16)    return 'd0;
    else if (lat <= 64)    return 'd1;
    else if (lat <= 256)   return 'd2;
    else if (lat <= 1024)  return 'd3;
    else if (lat <= 4096)  return 'd4;
    else                   return 'd5;
  endfunction

  function automatic logic [CmsCntW-1:0] cms_hart_id(logic [CmsCntW-1:0] g,
                                                     logic [CmsCntW-1:0] t,
                                                     logic [CmsCntW-1:0] c);
    return g * NumTilesPerGroup * NumCoresPerTile + t * NumCoresPerTile + c;
  endfunction

  // ---------------------------------------------------------------------------
  // Cycle counter
  // ---------------------------------------------------------------------------
  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) cms_cycle <= '0;
    else         cms_cycle <= cms_cycle + 1'b1;
  end

  // ---------------------------------------------------------------------------
  // Per-(g,t,c,p) allocator / deallocator
  //   Upward XMR: mempool_tb.dut.i_mempool_cluster... — resolved by SV name
  //   resolution since u_cms is instantiated inside mempool_tb.
  // ---------------------------------------------------------------------------
  generate
    for (genvar G = 0; G < NumGroups; G++) begin : gen_cms_g
      for (genvar T = 0; T < NumTilesPerGroup; T++) begin : gen_cms_t
        for (genvar C = 0; C < NumCoresPerTile; C++) begin : gen_cms_c
          for (genvar P = 0; P < NumDataPortsPerCore; P++) begin : gen_cms_p

            // XMR aliases — single source of truth for the deep path
            wire        q_vld   = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_qvalid[C][P];
            wire        q_rdy   = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_qready[C][P];
            wire [31:0] q_addr  = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_qaddr[C][P];
            wire        q_wr    = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_qwrite[C][P];
            wire [MetaIdWidth-1:0]   q_id = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_qid[C][P];
            wire [BurstLenWidth-1:0] q_bl = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_qburst_len[C][P];
            wire        p_vld   = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_pvalid[C][P];
            wire        p_rdy   = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_pready[C][P];
            wire [MetaIdWidth-1:0]   p_id = mempool_tb.dut.i_mempool_cluster.gen_groups_x[G/NumY].gen_groups_y[G%NumY]
                                      .gen_rtl_group.i_group.i_mempool_group
                                      .gen_tiles[T].i_tile.snitch_data_pid[C][P];

            // Per-port live status (waveform-friendly, derived from cms_tbl)
            logic [CmsCntW-1:0] cms_inflight_now;
            logic [CmsCycW-1:0] cms_oldest_age;
            always_comb begin
              automatic logic [CmsCntW-1:0] cnt    = '0;
              automatic logic [CmsCycW-1:0] oldest = '0;
              for (int i = 0; i < CMS_MaxId; i++) begin
                if (cms_tbl[G][T][C][P][i].valid) begin
                  cnt = cnt + 1'b1;
                  if ((cms_cycle - cms_tbl[G][T][C][P][i].cycle_issued) > oldest)
                    oldest = cms_cycle - cms_tbl[G][T][C][P][i].cycle_issued;
                end
              end
              cms_inflight_now = cnt;
              cms_oldest_age   = oldest;
            end

            always @(posedge clk_i or negedge rst_ni) begin
              if (!rst_ni) begin
                cms_n_req[G][T][C][P]         <= '0;
                cms_n_resp_beats[G][T][C][P]  <= '0;
                cms_n_resp_done[G][T][C][P]   <= '0;
                cms_n_read[G][T][C][P]        <= '0;
                cms_n_write[G][T][C][P]       <= '0;
                cms_n_inflight[G][T][C][P]    <= '0;
                cms_n_inflight_hw[G][T][C][P] <= '0;
                cms_n_orphan[G][T][C][P]      <= '0;
                cms_n_dup_alloc[G][T][C][P]   <= '0;
                cms_lat_sum[G][T][C][P]       <= '0;
                cms_lat_max[G][T][C][P]       <= '0;
                cms_tbl[G][T][C][P]           <= '0;  // clears all entries incl. valid
                cms_lat_hist[G][T][C][P]      <= '0;
              end else begin
                automatic logic q_hs      = q_vld && q_rdy;
                automatic logic p_hs      = p_vld && p_rdy;
                automatic logic resp_full = 1'b0;
                automatic int   infl_delta = 0;  // signed: +alloc / -full-dealloc

                // ---------------- Response ----------------
                if (p_hs) begin
                  cms_n_resp_beats[G][T][C][P] <= cms_n_resp_beats[G][T][C][P] + 1'b1;
                  if (!cms_tbl[G][T][C][P][p_id].valid && !(q_hs && q_id == p_id)) begin
                    cms_n_orphan[G][T][C][P] <= cms_n_orphan[G][T][C][P] + 1'b1;
                    $display("[CMS WARN] cyc=%0d g=%0d t=%0d c=%0d p=%0d hart=0x%0h ORPHAN_RESP id=%0d",
                             cms_cycle, G, T, C, P, cms_hart_id(G,T,C), p_id);
                  end else if (cms_tbl[G][T][C][P][p_id].valid) begin
                    automatic logic [BurstLenWidth:0] beats_after = cms_tbl[G][T][C][P][p_id].beats_recv + 1'b1;
                    automatic logic [CmsCycW-1:0]     lat         = cms_cycle - cms_tbl[G][T][C][P][p_id].cycle_issued;
                    if (beats_after >= cms_tbl[G][T][C][P][p_id].burst_len) begin
                      cms_tbl[G][T][C][P][p_id].valid <= 1'b0;
                      cms_n_resp_done[G][T][C][P]  <= cms_n_resp_done[G][T][C][P] + 1'b1;
                      cms_lat_sum[G][T][C][P]      <= cms_lat_sum[G][T][C][P] + lat;
                      if (lat > cms_lat_max[G][T][C][P]) cms_lat_max[G][T][C][P] <= lat;
                      cms_lat_hist[G][T][C][P][cms_lat_bucket(lat)]
                          <= cms_lat_hist[G][T][C][P][cms_lat_bucket(lat)] + 1'b1;
                      resp_full = 1'b1;
                    end else begin
                      cms_tbl[G][T][C][P][p_id].beats_recv <= beats_after[BurstLenWidth-1:0];
                    end
                  end
                end
                if (resp_full) infl_delta = infl_delta - 1;

                // ---------------- Request -----------------
                // A burst request (qburst_len = N) is expanded by the tile/MSHR
                // into N word responses with pids q_id, q_id+1, ..., q_id+N-1
                // (see tcdm_burst_expander.sv and the meta_id_base+offset math
                // in mempool_group_mshr.sv). To match this, the VIP allocates
                // N entries — one per expected beat id — each with burst_len=1.
                if (q_hs) begin
                  automatic logic [BurstLenWidth-1:0] bl_eff = (q_bl == 0) ? BurstLenWidth'(1) : q_bl;
                  for (int b = 0; b < (1 << BurstLenWidth); b++) begin
                    if (b < int'(bl_eff)) begin
                      automatic logic [MetaIdWidth-1:0] beat_id = q_id + meta_id_t'(b);
                      // Dup detection: suppress if the same beat-id is being
                      // fully responded to in this very cycle (resp_full + match)
                      if (cms_tbl[G][T][C][P][beat_id].valid
                          && !(p_hs && p_id == beat_id && resp_full)) begin
                        cms_n_dup_alloc[G][T][C][P] <= cms_n_dup_alloc[G][T][C][P] + 1'b1;
                        $display("[CMS WARN] cyc=%0d g=%0d t=%0d c=%0d p=%0d hart=0x%0h DUP_ALLOC id=%0d (burst_base=%0d beat=%0d) prev_cyc=%0d prev_addr=0x%08x new_addr=0x%08x",
                                 cms_cycle, G, T, C, P, cms_hart_id(G,T,C),
                                 beat_id, q_id, b,
                                 cms_tbl[G][T][C][P][beat_id].cycle_issued,
                                 cms_tbl[G][T][C][P][beat_id].addr,
                                 q_addr);
                      end
                      cms_tbl[G][T][C][P][beat_id].valid        <= 1'b1;
                      cms_tbl[G][T][C][P][beat_id].cycle_issued <= cms_cycle;
                      cms_tbl[G][T][C][P][beat_id].addr         <= q_addr;
                      cms_tbl[G][T][C][P][beat_id].is_write     <= q_wr;
                      cms_tbl[G][T][C][P][beat_id].burst_len    <= BurstLenWidth'(1);
                      cms_tbl[G][T][C][P][beat_id].beats_recv   <= '0;
                      cms_tbl[G][T][C][P][beat_id].warned       <= 1'b0;
                    end
                  end

                  cms_n_req[G][T][C][P] <= cms_n_req[G][T][C][P] + CmsCntW'(bl_eff);
                  if (q_wr) cms_n_write[G][T][C][P] <= cms_n_write[G][T][C][P] + CmsCntW'(bl_eff);
                  else      cms_n_read[G][T][C][P]  <= cms_n_read[G][T][C][P]  + CmsCntW'(bl_eff);
                  infl_delta = infl_delta + int'(bl_eff);
                end

                if (infl_delta != 0) begin
                  cms_n_inflight[G][T][C][P]
                      <= cms_n_inflight[G][T][C][P] + infl_delta;
                  if (infl_delta > 0 &&
                      cms_n_inflight[G][T][C][P] + infl_delta
                          > cms_n_inflight_hw[G][T][C][P]) begin
                    cms_n_inflight_hw[G][T][C][P]
                        <= cms_n_inflight[G][T][C][P] + infl_delta;
                  end
                end
              end
            end

          end : gen_cms_p
        end : gen_cms_c
      end : gen_cms_t
    end : gen_cms_g
  endgenerate

  // ---------------------------------------------------------------------------
  // Periodic scan for stuck inflight requests
  // ---------------------------------------------------------------------------
  task automatic cms_scan_stuck;
    logic [CmsCntW-1:0] n_stuck_new = '0;
    logic [CmsCntW-1:0] n_stuck_tot = '0;
    for (int g = 0; g < NumGroups; g++) begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int c = 0; c < NumCoresPerTile; c++) begin
          for (int p = 0; p < NumDataPortsPerCore; p++) begin
            for (int i = 0; i < CMS_MaxId; i++) begin
              if (cms_tbl[g][t][c][p][i].valid) begin
                automatic logic [CmsCycW-1:0] age = cms_cycle - cms_tbl[g][t][c][p][i].cycle_issued;
                if (age >= `CMS_STUCK_THRESHOLD) begin
                  n_stuck_tot = n_stuck_tot + 1'b1;
                  if (!cms_tbl[g][t][c][p][i].warned) begin
                    cms_tbl[g][t][c][p][i].warned = 1'b1;
                    n_stuck_new = n_stuck_new + 1'b1;
                    $display("[CMS WARN] cyc=%0d STUCK_REQ g=%0d t=%0d c=%0d p=%0d hart=0x%0h id=%0d age=%0d addr=0x%08x %s bl=%0d beats=%0d",
                             cms_cycle, g, t, c, p, cms_hart_id(g,t,c),
                             i, age,
                             cms_tbl[g][t][c][p][i].addr,
                             cms_tbl[g][t][c][p][i].is_write ? "W" : "R",
                             cms_tbl[g][t][c][p][i].burst_len,
                             cms_tbl[g][t][c][p][i].beats_recv);
                  end
                end
              end
            end
          end
        end
      end
    end
    if (n_stuck_tot > 0)
      $display("[CMS] cyc=%0d stuck_summary: total_stuck=%0d newly_warned=%0d",
               cms_cycle, n_stuck_tot, n_stuck_new);
  endtask

  // ---------------------------------------------------------------------------
  // Periodic summary
  // ---------------------------------------------------------------------------
  task automatic cms_period_summary;
    logic [CmsCycW-1:0] total_req  = '0;
    logic [CmsCycW-1:0] total_resp = '0;
    logic [CmsCycW-1:0] total_infl = '0;
    logic [CmsCycW-1:0] total_orph = '0;
    logic [CmsCycW-1:0] total_dup  = '0;
    logic [CmsCntW-1:0] max_infl   = '0;
    logic [CmsCntW-1:0] max_g = '0, max_t = '0, max_c = '0, max_p = '0;
    for (int g = 0; g < NumGroups; g++) begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int c = 0; c < NumCoresPerTile; c++) begin
          for (int p = 0; p < NumDataPortsPerCore; p++) begin
            total_req  = total_req  + cms_n_req[g][t][c][p];
            total_resp = total_resp + cms_n_resp_done[g][t][c][p];
            total_infl = total_infl + cms_n_inflight[g][t][c][p];
            total_orph = total_orph + cms_n_orphan[g][t][c][p];
            total_dup  = total_dup  + cms_n_dup_alloc[g][t][c][p];
            if (cms_n_inflight[g][t][c][p] > max_infl) begin
              max_infl = cms_n_inflight[g][t][c][p];
              max_g = g[CmsCntW-1:0]; max_t = t[CmsCntW-1:0];
              max_c = c[CmsCntW-1:0]; max_p = p[CmsCntW-1:0];
            end
          end
        end
      end
    end
    $display("[CMS] cyc=%0d period_summary: req=%0d resp=%0d inflight=%0d orphan=%0d dup_alloc=%0d top_inflight={g=%0d,t=%0d,c=%0d,p=%0d,hart=0x%0h,n=%0d}",
             cms_cycle, total_req, total_resp, total_infl, total_orph, total_dup,
             max_g, max_t, max_c, max_p, cms_hart_id(max_g,max_t,max_c), max_infl);
  endtask

  initial begin
    @(posedge rst_ni);
    forever begin
      @(posedge clk_i);
      if (cms_cycle > 0 && (cms_cycle % `CMS_REPORT_PERIOD) == 0) begin
        if (`CMS_GATE_BENCHMARK == 0 || cms_benchmark_active) begin
          cms_scan_stuck();
          cms_period_summary();
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // End-of-simulation dump
  // ---------------------------------------------------------------------------
  final begin
    automatic logic [CmsCycW-1:0] tot_req         = '0;
    automatic logic [CmsCycW-1:0] tot_resp        = '0;
    automatic logic [CmsCycW-1:0] tot_orph        = '0;
    automatic logic [CmsCycW-1:0] tot_dup         = '0;
    automatic logic [CmsCycW-1:0] tot_lat         = '0;
    automatic logic [CmsCycW-1:0] n_lat_samples   = '0;
    automatic logic [CmsCntW-1:0] n_stuck_ports   = '0;
    automatic logic [CmsCntW-1:0] n_stuck_entries = '0;

    $display("");
    $display("============================================================");
    $display("[CMS FINAL] Core Memory Scoreboard summary @ cyc=%0d", cms_cycle);
    $display("============================================================");

    for (int g = 0; g < NumGroups; g++) begin
      for (int t = 0; t < NumTilesPerGroup; t++) begin
        for (int c = 0; c < NumCoresPerTile; c++) begin
          for (int p = 0; p < NumDataPortsPerCore; p++) begin
            tot_req  = tot_req  + cms_n_req[g][t][c][p];
            tot_resp = tot_resp + cms_n_resp_done[g][t][c][p];
            tot_orph = tot_orph + cms_n_orphan[g][t][c][p];
            tot_dup  = tot_dup  + cms_n_dup_alloc[g][t][c][p];
            tot_lat  = tot_lat  + cms_lat_sum[g][t][c][p];
            n_lat_samples = n_lat_samples + cms_n_resp_done[g][t][c][p];

            if (cms_n_inflight[g][t][c][p] > 0) begin
              n_stuck_ports = n_stuck_ports + 1'b1;
              $display("[CMS FINAL] STILL_INFLIGHT g=%0d t=%0d c=%0d p=%0d hart=0x%0h  inflight=%0d  req=%0d  resp=%0d  resp_beats=%0d  hw=%0d  avg_lat=%0d  max_lat=%0d",
                       g, t, c, p, cms_hart_id(g,t,c),
                       cms_n_inflight[g][t][c][p],
                       cms_n_req[g][t][c][p],
                       cms_n_resp_done[g][t][c][p],
                       cms_n_resp_beats[g][t][c][p],
                       cms_n_inflight_hw[g][t][c][p],
                       cms_n_resp_done[g][t][c][p] == 0 ? '0
                           : (cms_lat_sum[g][t][c][p] / cms_n_resp_done[g][t][c][p]),
                       cms_lat_max[g][t][c][p]);
              for (int i = 0; i < CMS_MaxId; i++) begin
                if (cms_tbl[g][t][c][p][i].valid) begin
                  n_stuck_entries = n_stuck_entries + 1'b1;
                  $display("[CMS FINAL]   id=%0d  cyc_issued=%0d  age=%0d  addr=0x%08x  %s  bl=%0d  beats=%0d",
                           i,
                           cms_tbl[g][t][c][p][i].cycle_issued,
                           cms_cycle - cms_tbl[g][t][c][p][i].cycle_issued,
                           cms_tbl[g][t][c][p][i].addr,
                           cms_tbl[g][t][c][p][i].is_write ? "W" : "R",
                           cms_tbl[g][t][c][p][i].burst_len,
                           cms_tbl[g][t][c][p][i].beats_recv);
                end
              end
            end
          end
        end
      end
    end

    $display("------------------------------------------------------------");
    $display("[CMS FINAL] global: req=%0d  resp=%0d  inflight_ports=%0d  inflight_entries=%0d  orphan=%0d  dup_alloc=%0d  avg_lat=%0d",
             tot_req, tot_resp, n_stuck_ports, n_stuck_entries, tot_orph, tot_dup,
             n_lat_samples == 0 ? '0 : (tot_lat / n_lat_samples));

    // Aggregate latency histogram
    begin
      automatic logic [CMS_NumLatBuckets-1:0][CmsCntW-1:0] hist = '0;
      // String labels cannot live in a packed array (string is non-integral).
      automatic string lbl [CMS_NumLatBuckets] = '{"<=16","<=64","<=256","<=1024","<=4096",">4096"};
      for (int g = 0; g < NumGroups; g++)
        for (int t = 0; t < NumTilesPerGroup; t++)
          for (int c = 0; c < NumCoresPerTile; c++)
            for (int p = 0; p < NumDataPortsPerCore; p++)
              for (int b = 0; b < CMS_NumLatBuckets; b++)
                hist[b] = hist[b] + cms_lat_hist[g][t][c][p][b];
      $display("[CMS FINAL] latency histogram (cycles):");
      for (int b = 0; b < CMS_NumLatBuckets; b++)
        $display("[CMS FINAL]   %-7s : %0d", lbl[b], hist[b]);
    end

    $display("============================================================");
  end

endmodule : tb_core_mem_scoreboard

`endif // !CMS_DISABLE
`endif // !VERILATOR
// pragma translate_on
