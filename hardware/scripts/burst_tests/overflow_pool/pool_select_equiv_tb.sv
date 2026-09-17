`timescale 1ns/1ps

// Check the selection algebra independently of the pool lifecycle. The reference
// retains lane-order writes; the replacement gathers with one-hot masked ORs.
module pool_select_equiv_case #(
  parameter int Lanes = 32,
  parameter int Pools = 1,
  parameter int Trials = 200000,
  parameter int PayloadW = 128
) (output bit done_o);
  logic [Lanes-1:0] cand, rr_mask, hi, lo, winner, accept;
  logic [Lanes-1:0][PayloadW-1:0] payload;
  logic [PayloadW-1:0] selected_ref, selected_or;
  logic accepted_ref, accepted_or;
  logic [Pools-1:0][Lanes-1:0] want, first, second;
  logic [Lanes-1:0] rest;
  logic [Pools-1:0] grant1, grant2;
  logic [Pools-1:0][PayloadW-1:0] capture0_ref, capture1_ref;
  logic [Pools-1:0][PayloadW-1:0] capture0_or, capture1_or;
  int lane_pool[Lanes];
  int rr_base, two_capture_cases, empty_cases, seed;

  initial begin
    done_o = 0;
    two_capture_cases = 0;
    empty_cases = 0;
    seed = 32'h71d30000 + Lanes * 16 + Pools;
    seed = $urandom(seed);
    for (int trial = 0; trial < Trials; trial++) begin
      rr_base = $urandom_range(Lanes - 1);
      for (int l = 0; l < Lanes; l++) begin
        cand[l] = ($urandom_range(3) != 0);
        accept[l] = $urandom_range(1);
        rr_mask[l] = (l >= rr_base);
        for (int b = 0; b < PayloadW; b += 32) begin
          payload[l][b +: 32] = $urandom;
        end
      end
      // Exercise empty and every individual winner deterministically before the
      // random contention cases, including unknown data on every losing lane.
      if (trial <= Lanes) begin
        cand = '0;
        if (trial != 0) cand[trial - 1] = 1'b1;
      end
      hi = cand & rr_mask;
      lo = cand & ~rr_mask;
      winner = (|hi) ? (hi & (~hi + Lanes'(1))) : (lo & (~lo + Lanes'(1)));
      if (!$onehot0(winner)) $fatal(1, "request selector is not onehot0");
      for (int l = 0; l < Lanes; l++) begin
        if ((trial <= Lanes) && !winner[l]) payload[l] = 'x;
      end
      selected_ref = '0;
      selected_or = '0;
      accepted_ref = 0;
      accepted_or = |(winner & accept);
      for (int l = 0; l < Lanes; l++) begin
        if (winner[l]) begin
          selected_ref = payload[l];
          accepted_ref = accept[l];
        end
        selected_or |= {PayloadW{winner[l]}} & payload[l];
      end
      if ((selected_ref !== selected_or) || (accepted_ref !== accepted_or)) begin
        $fatal(1, "request mismatch lanes=%0d trial=%0d", Lanes, trial);
      end
      if (!(|winner)) empty_cases++;

      // Each response lane can name at most one entry. The first two matching
      // lanes are accepted according to that entry's registered free credits.
      want = '0;
      for (int l = 0; l < Lanes; l++) begin
        lane_pool[l] = $urandom_range(Pools - 1);
        want[lane_pool[l]][l] = $urandom_range(1);
        for (int b = 0; b < PayloadW; b += 32) begin
          payload[l][b +: 32] = $urandom;
        end
      end
      for (int p = 0; p < Pools; p++) begin
        first[p] = want[p] & (~want[p] + Lanes'(1));
        rest = want[p] & ~first[p];
        second[p] = rest & (~rest + Lanes'(1));
        grant1[p] = (|first[p]) && ($urandom_range(3) != 0);
        grant2[p] = grant1[p] && (|second[p]) && $urandom_range(1);
        if (!$onehot0(first[p]) || !$onehot0(second[p]) || (|(first[p] & second[p]))) begin
          $fatal(1, "capture selectors overlap or are not onehot0");
        end
        if (grant2[p]) two_capture_cases++;
      end
      capture0_ref = '0;
      capture1_ref = '0;
      capture0_or = '0;
      capture1_or = '0;
      for (int l = 0; l < Lanes; l++) begin
        if (first[lane_pool[l]][l] && grant1[lane_pool[l]]) begin
          capture0_ref[lane_pool[l]] = payload[l];
        end else if (second[lane_pool[l]][l] && grant2[lane_pool[l]]) begin
          capture1_ref[lane_pool[l]] = payload[l];
        end
      end
      for (int p = 0; p < Pools; p++) begin
        for (int l = 0; l < Lanes; l++) begin
          capture0_or[p] |= {PayloadW{first[p][l]}} & payload[l];
          capture1_or[p] |= {PayloadW{second[p][l]}} & payload[l];
        end
        // The real storage observes these operands only when its grant fires.
        if ((grant1[p] && (capture0_ref[p] !== capture0_or[p])) ||
            (grant2[p] && (capture1_ref[p] !== capture1_or[p]))) begin
          $fatal(1, "capture mismatch lanes=%0d pools=%0d trial=%0d", Lanes, Pools, trial);
        end
      end
    end
    if ((empty_cases == 0) || ((Lanes > 1) && (two_capture_cases == 0))) begin
      $fatal(1, "missing empty-winner or two-capture coverage");
    end
    $display("PASS selection lanes=%0d pools=%0d trials=%0d empty=%0d two_capture=%0d",
             Lanes, Pools, Trials, empty_cases, two_capture_cases);
    done_o = 1;
  end
endmodule

module pool_select_equiv_tb;
  wire [5:0] done;
  pool_select_equiv_case #(.Lanes(1), .Pools(1)) i_one(done[0]);
  pool_select_equiv_case #(.Lanes(2), .Pools(1)) i_two(done[1]);
  pool_select_equiv_case #(.Lanes(4), .Pools(3)) i_small_pool(done[2]);
  pool_select_equiv_case #(.Lanes(32), .Pools(1)) i_32(done[3]);
  pool_select_equiv_case #(.Lanes(48), .Pools(1)) i_48(done[4]);
  pool_select_equiv_case #(.Lanes(48), .Pools(3)) i_48_pool(done[5]);
  initial begin
    wait (&done);
    $display("PASS pool selection equivalence: 1200000 vectors, six parameter sets");
    $finish;
  end
endmodule
