// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Group MSHR runtime configuration file.
//
// One instance per group. Written by software through the group-barrier port's unused op encoding
// (bank field == 3), so this costs no new address space and no new crossbar decode -- see
// docs/mshr_runtime_csr_design.md for the address map.
//
// RESET VALUES ARE THE ELABORATED CONSTANTS. An unconfigured run must be bit-identical to the
// pre-CSR design; that is verification gate V1 and it is the reason every default is a parameter
// rather than a literal.
//
// WHY THE HARDWARE ENFORCES RANGES INSTEAD OF TRUSTING SOFTWARE. Every elaboration `$error` that
// guarded one of these parameters becomes a RUNTIME check once the parameter is writable. A write
// that would create a configuration the design forbids is REFUSED and recorded in a sticky status
// bit, never silently accepted -- software reads the status back and fails loudly. Accepting a bad
// write would reproduce the failure mode that cost three invalid measurement runs on 2026-08-14: a
// configuration that differs from the one requested, with nothing to indicate it.

module mempool_group_mshr_cfg
  import mempool_pkg::*;
#(
  // 0 = every field const-folds to its default and the whole file disappears (fixed-function
  // build, bit-identical to pre-CSR). 1 = software-writable.
  parameter bit          CfgRuntime          = 1'b0,
  // Defaults == the values this config elaborates today.
  parameter int unsigned DefHoldSubsSingle   = 2,
  parameter int unsigned DefHoldSubsBurst    = 2,
  parameter int unsigned DefHoldWindowSingle = 0,
  parameter int unsigned DefHoldWindowBurst  = 0,
  parameter int unsigned DefServeTimeout     = 0,
  parameter int unsigned DefBankShiftSingle  = 5,
  parameter int unsigned DefBankShiftBurst   = 5,
  parameter int unsigned DefBankBurstBits    = 0,
  // 0 = legacy (self-invalidate at hold_subs / re-arm cache phase from serve_timeout).
  parameter int unsigned DefCacheReuseTarget = 0,
  parameter int unsigned DefCacheTimeout     = 0,
  // Legal ranges, enforced at runtime.
  parameter int unsigned MergeReqs           = 4,     // hold_subs upper bound
  parameter int unsigned HoldCntHwMax        = 2047,  // window/timeout upper bound
  parameter int unsigned BankShiftMin        = 5,
  parameter int unsigned BankShiftMax        = 10,
  // Burst-hash overlap floor. The static [BankShiftMin,BankShiftMax] window is NOT the real
  // rule: mempool_group_mshr.sv:525 requires bank_shift_burst >= BurstAlignBits + bank_burst_bits,
  // which equals BankShiftMin(5) only at bank_burst_bits<=1. At bank_burst_bits=2 (LMUL=4) the
  // true floor is 6, so a runtime write of 5 would pass the window check and still overlap the
  // intra-load burst bits -- double-counting a bit and collapsing half the banks, with no
  // elaboration $error to catch it because that assertion sees only the reset values.
  // Checked at ENABLE rather than per write: software sets BANK_SHIFT_BURST before
  // BANK_BURST_BITS, so a per-write test would compare against a stale burst_bits.
  parameter int unsigned BurstAlignBits      = 4,
  // Mirrors the MSHR's elaboration guard at mempool_group_mshr.sv:328 -- serve_timeout == 0 pins a
  // CACHED way forever when the serve target is never reached and the entry is not an eviction
  // victim. Only then is 0 refused.
  parameter bit          ServeTimeoutMustBeNonZero = 1'b0,
  // CSR index width (4 bits = 16 CSRs, matching the barrier's struct field).
  parameter int unsigned IdxW                = 4
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  // Decoded CSR write from the group-barrier port.
  input  logic             wr_valid_i,
  input  logic [IdxW-1:0]  wr_idx_i,
  input  logic [31:0]      wr_data_i,
  // MSHR occupancy. A bank-hash change with entries resident is a CORRECTNESS hazard, not a
  // preference: the bank index both PLACES an entry and LOOKS IT UP, so re-hashing mid-flight makes
  // a lookup probe the wrong bank -- the line misses, a second entry is allocated for an address
  // that already has one, and two entries shadow the same line. Refuse rather than trust ordering.
  input  logic             mshr_busy_i,
  output mshr_cfg_t        cfg_o,
  output logic [31:0]      status_o
);

  // ---------------------------------------------------------------------------------------------
  // Fixed-function build: no storage, no write port, everything folds to the defaults.
  // ---------------------------------------------------------------------------------------------
  if (!CfgRuntime) begin : gen_static_cfg
    assign cfg_o = '{
      enable            : 1'b1,
      hold_subs_single  : MshrCfgSubsW'(DefHoldSubsSingle),
      hold_subs_burst   : MshrCfgSubsW'(DefHoldSubsBurst),
      hold_window_single: MshrCfgHoldCntW'(DefHoldWindowSingle),
      hold_window_burst : MshrCfgHoldCntW'(DefHoldWindowBurst),
      serve_timeout     : MshrCfgHoldCntW'(DefServeTimeout),
      bank_shift_single : MshrCfgShiftW'(DefBankShiftSingle),
      bank_shift_burst  : MshrCfgShiftW'(DefBankShiftBurst),
      bank_burst_bits   : (DefBankBurstBits != 0),
      cache_reuse_target: MshrCfgSubsW'(DefCacheReuseTarget),
      cache_timeout     : MshrCfgHoldCntW'(DefCacheTimeout)
    };
    assign status_o = '0;
    // Silence unused-input lint in this arm.
    logic unused;
    assign unused = &{1'b0, wr_valid_i, wr_idx_i, wr_data_i, mshr_busy_i};

  end else begin : gen_runtime_cfg
  // ---------------------------------------------------------------------------------------------
  // Runtime build.
  // ---------------------------------------------------------------------------------------------
    mshr_cfg_t   cfg_q, cfg_d;
    logic [31:0] status_q, status_d;

    // ⚠ THE FIELD MUST BE ABLE TO HOLD WHAT THE RANGE CHECK ADMITS.
    // subs_ok validates the full 32-bit write, and the accept path then casts to MshrCfgSubsW. If
    // the field is narrower than MergeReqs, a value that PASSES the check is silently truncated on
    // the way in. That is exactly what happened at MshrCfgSubsW=4 with MergeReqs=16: every
    // 128x*x512 shape wrote 16, stored 0, and stopped merging singles -- measured merged_single
    // 230,224 -> 179,222 with alloc_single 15,356 -> 48,816, which read as a 43% "improvement".
    // Third instance of this bug class after HoldCntW and ServedCntMax, and the only one that fired
    // in a shipped configuration. Catch it at elaboration rather than in a benchmark table.
    if ((32'd1 << MshrCfgSubsW) <= MergeReqs)
      $error("[mshr_cfg] MshrCfgSubsW=%0d cannot represent MergeReqs=%0d; a legal write would truncate.",
             MshrCfgSubsW, MergeReqs);
    if ((32'd1 << MshrCfgHoldCntW) <= HoldCntHwMax)
      $error("[mshr_cfg] MshrCfgHoldCntW=%0d cannot represent HoldCntHwMax=%0d; a legal write would truncate.",
             MshrCfgHoldCntW, HoldCntHwMax);

    // Range checks. Each mirrors an elaboration guard in mempool_group_mshr.sv.
    logic subs_ok, cnt_ok, shift_s_ok, shift_b_ok, tmo_ok, burst_hash_ok, reuse_ok;
    assign subs_ok    = (wr_data_i >= 32'd1) && (wr_data_i <= MergeReqs);
    assign cnt_ok     = (wr_data_i <= HoldCntHwMax);
    assign shift_s_ok = (wr_data_i >= BankShiftMin) && (wr_data_i <= BankShiftMax);
    assign shift_b_ok = shift_s_ok;
    // serve_timeout == 0 means "never expires"; legal unless the MSHR config needs the backstop.
    assign tmo_ok     = cnt_ok && !(ServeTimeoutMustBeNonZero && (wr_data_i == 32'd0));
    // Reuse target: same upper bound as hold_subs (served_cnt saturates at MergeReqs, so anything
    // above is unreachable), but 0 is additionally legal and means "legacy self-invalidate".
    assign reuse_ok   = (wr_data_i <= MergeReqs);
    // Evaluated on the SETTLED config, not on wr_data_i, because the two fields arrive in
    // separate writes.
    assign burst_hash_ok = (32'(cfg_q.bank_shift_burst) >=
                            32'(BurstAlignBits) + 32'(cfg_q.bank_burst_bits));

    always_comb begin
      cfg_d    = cfg_q;
      status_d = status_q;   // sticky: only software-visible clear (write of index 15) resets it
      if (wr_valid_i) begin
        unique case (wr_idx_i)
          IdxW'(MSHR_CSR_ENABLE)             : if (!wr_data_i[0]) cfg_d.enable = 1'b0;
                                               // Arming with an overlapping burst hash is a
                                               // silent-corruption config, so refuse to arm and
                                               // leave the MSHR disabled: the TB already shouts
                                               // "[MSHRCFG WARN] ... MSHR DISABLED" on that, which
                                               // is far louder than a quietly halved bank count.
                                               else if (burst_hash_ok) cfg_d.enable = 1'b1;
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_HOLD_SUBS_SINGLE)   : if (subs_ok) cfg_d.hold_subs_single = MshrCfgSubsW'(wr_data_i);
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_HOLD_SUBS_BURST)    : if (subs_ok) cfg_d.hold_subs_burst  = MshrCfgSubsW'(wr_data_i);
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_HOLD_WINDOW_SINGLE) : if (cnt_ok)  cfg_d.hold_window_single = MshrCfgHoldCntW'(wr_data_i);
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_HOLD_WINDOW_BURST)  : if (cnt_ok)  cfg_d.hold_window_burst  = MshrCfgHoldCntW'(wr_data_i);
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_SERVE_TIMEOUT)      : if (tmo_ok)  cfg_d.serve_timeout      = MshrCfgHoldCntW'(wr_data_i);
                                               else if (!cnt_ok) status_d[MSHR_STATUS_RANGE]        = 1'b1;
                                               else              status_d[MSHR_STATUS_TIMEOUT_ZERO] = 1'b1;
          // The three bank-hash CSRs are the only ones gated on an empty MSHR.
          IdxW'(MSHR_CSR_BANK_SHIFT_SINGLE)  : if (mshr_busy_i)      status_d[MSHR_STATUS_BANK_BUSY] = 1'b1;
                                               else if (!shift_s_ok) status_d[MSHR_STATUS_RANGE]     = 1'b1;
                                               else cfg_d.bank_shift_single = MshrCfgShiftW'(wr_data_i);
          IdxW'(MSHR_CSR_BANK_SHIFT_BURST)   : if (mshr_busy_i)      status_d[MSHR_STATUS_BANK_BUSY] = 1'b1;
                                               else if (!shift_b_ok) status_d[MSHR_STATUS_RANGE]     = 1'b1;
                                               else cfg_d.bank_shift_burst = MshrCfgShiftW'(wr_data_i);
          IdxW'(MSHR_CSR_BANK_BURST_BITS)    : if (mshr_busy_i) status_d[MSHR_STATUS_BANK_BUSY] = 1'b1;
                                               else cfg_d.bank_burst_bits = wr_data_i[0];
          IdxW'(MSHR_CSR_CACHE_REUSE_TARGET) : if (reuse_ok) cfg_d.cache_reuse_target = MshrCfgSubsW'(wr_data_i);
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_CACHE_TIMEOUT)      : if (cnt_ok)   cfg_d.cache_timeout      = MshrCfgHoldCntW'(wr_data_i);
                                               else status_d[MSHR_STATUS_RANGE] = 1'b1;
          IdxW'(MSHR_CSR_STATUS)             : status_d = '0;   // write to 15 clears the sticky bits
          default                            : status_d[MSHR_STATUS_BAD_INDEX] = 1'b1;
        endcase
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        cfg_q <= '{
          enable            : 1'b0,   // DEFAULT BYPASSED: init and warm-up never allocate
          hold_subs_single  : MshrCfgSubsW'(DefHoldSubsSingle),
          hold_subs_burst   : MshrCfgSubsW'(DefHoldSubsBurst),
          hold_window_single: MshrCfgHoldCntW'(DefHoldWindowSingle),
          hold_window_burst : MshrCfgHoldCntW'(DefHoldWindowBurst),
          serve_timeout     : MshrCfgHoldCntW'(DefServeTimeout),
          bank_shift_single : MshrCfgShiftW'(DefBankShiftSingle),
          bank_shift_burst  : MshrCfgShiftW'(DefBankShiftBurst),
          bank_burst_bits   : (DefBankBurstBits != 0),
          cache_reuse_target: MshrCfgSubsW'(DefCacheReuseTarget),
          cache_timeout     : MshrCfgHoldCntW'(DefCacheTimeout)
        };
        status_q <= '0;
      end else begin
        cfg_q    <= cfg_d;
        status_q <= status_d;
      end
    end

    assign cfg_o    = cfg_q;
    assign status_o = status_q;

`ifndef TARGET_SYNTHESIS
  `ifndef VERILATOR
    // pragma translate_off
    // The hazard this file exists to prevent: a bank-hash field must never change while entries
    // are resident. The refusal above makes it structurally impossible; this catches a future edit
    // that removes the gate.
    bank_hash_stable_while_valid : assert property (@(posedge clk_i) disable iff (!rst_ni)
        mshr_busy_i |-> ($stable(cfg_q.bank_shift_single) &&
                         $stable(cfg_q.bank_shift_burst)  &&
                         $stable(cfg_q.bank_burst_bits)))
      else $fatal(1, "[mshr_cfg] bank hash changed while the MSHR held valid entries");
    // pragma translate_on
  `endif
`endif

  end

endmodule : mempool_group_mshr_cfg
