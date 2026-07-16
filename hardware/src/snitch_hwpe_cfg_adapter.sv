// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Adapt a backpressured Snitch request/response channel to the HWPE peripheral
// protocol, whose response channel has no ready signal. Keep at most one
// request outstanding and retain its response until the Snitch side accepts it.
module snitch_hwpe_cfg_adapter #(
  parameter type req_t  = snitch_pkg::dreq_t,
  parameter type resp_t = snitch_pkg::dresp_t
) (
  input  logic  clk_i,
  input  logic  rst_ni,

  input  req_t  req_i,
  input  logic  req_valid_i,
  output logic  req_ready_o,

  output resp_t resp_o,
  output logic  resp_valid_o,
  input  logic  resp_ready_i,

  hwpe_ctrl_intf_periph.master periph
);

  typedef enum logic [1:0] {
    Idle,
    Issue,
    WaitResponse,
    HoldResponse
  } state_e;

  state_e state_q;
  req_t   req_q;
  resp_t  resp_q;

  always_comb begin
    periph.req  = 1'b0;
    periph.add  = req_q.addr;
    periph.wen  = ~req_q.write;
    periph.be   = req_q.strb;
    periph.data = req_q.data;
    periph.id   = req_q.id;

    req_ready_o = 1'b0;
    resp_o       = resp_q;
    resp_valid_o = 1'b0;

    unique case (state_q)
      Idle: begin
        req_ready_o = 1'b1;
      end
      Issue: begin
        periph.req = 1'b1;
      end
      HoldResponse: begin
        resp_valid_o = 1'b1;
      end
      default: begin
        // Wait for the unbackpressured HWPE response.
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
      req_q   <= '0;
      resp_q  <= '0;
    end else begin
      unique case (state_q)
        Idle: begin
          if (req_valid_i && req_ready_o) begin
            req_q   <= req_i;
            state_q <= Issue;
          end
        end
        Issue: begin
          if (periph.req && periph.gnt) begin
            if (periph.r_valid) begin
              resp_q.data  <= periph.r_data;
              resp_q.id    <= req_q.id;
              resp_q.write <= req_q.write;
              resp_q.error <= 1'b0;
              state_q      <= HoldResponse;
            end else begin
              state_q <= WaitResponse;
            end
          end
        end
        WaitResponse: begin
          if (periph.r_valid) begin
            resp_q.data  <= periph.r_data;
            resp_q.id    <= req_q.id;
            resp_q.write <= req_q.write;
            resp_q.error <= 1'b0;
            state_q      <= HoldResponse;
          end
        end
        HoldResponse: begin
          if (resp_valid_o && resp_ready_i) begin
            state_q <= Idle;
          end
        end
        default: begin
          state_q <= Idle;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert (!(periph.r_valid &&
                !((state_q == WaitResponse) ||
                  ((state_q == Issue) && periph.req && periph.gnt))))
        else $error("HWPE response arrived without an accepted configuration request");
    end
  end
`endif

endmodule
