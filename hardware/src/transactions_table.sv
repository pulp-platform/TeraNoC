// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Realign tagged responses with IDs 0..NumTransactions-1. The one tagless
// store-response class uses exactly ID NumTransactions.
module transactions_table
  import cf_math_pkg::idx_width;
#(
  parameter int unsigned NumPorts             = 4,
  parameter int unsigned NumTransactions      = 8,
  parameter int unsigned TransactionsWidth    = idx_width(NumTransactions),
  parameter int unsigned StoreCountWidth      = 32 + idx_width(NumPorts),
  parameter type         resp_t                = logic
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  resp_t [NumPorts-1:0]    resp_payload_i,
  input  logic  [NumPorts-1:0]    resp_valid_i,
  output logic  [NumPorts-1:0]    resp_ready_o,
  output resp_t [NumPorts-1:0]    resp_payload_o,
  output logic  [NumPorts-1:0]    resp_valid_o,
  input  logic  [NumPorts-1:0]    resp_ready_i
);

  typedef logic [StoreCountWidth-1:0] store_count_t;

  localparam store_count_t StoreResponsesPerTransaction = NumPorts;

  resp_t [NumTransactions-1:0][NumPorts-1:0] table_data_d, table_data_q;
  logic  [NumTransactions-1:0][NumPorts-1:0] table_valid_d, table_valid_q;
  logic  [NumTransactions-1:0]               table_all_valid;
  logic  [TransactionsWidth-1:0]             selected_transaction;
  logic                                      tagged_response_available;

  store_count_t store_response_count_d, store_response_count_q;
  store_count_t store_response_arrivals;
  logic         store_response_available;

  resp_t [NumPorts-1:0] output_data_d, output_data_q;
  logic                  output_valid_d, output_valid_q;
  logic                  prefer_store_d, prefer_store_q;
  logic                  output_slot_available;
  logic                  select_store_response;

  for (genvar t = 0; t < NumTransactions; t++) begin: gen_table_all_valid
    assign table_all_valid[t] = &table_valid_q[t];
  end : gen_table_all_valid

  always_comb begin : select_response
    selected_transaction     = '0;
    tagged_response_available = 1'b0;
    for (int t = 0; t < NumTransactions; t++) begin
      if (table_all_valid[t]) begin
        selected_transaction      = TransactionsWidth'(t);
        tagged_response_available = 1'b1;
      end
    end

    store_response_available =
        store_response_count_q >= StoreResponsesPerTransaction;
    select_store_response = store_response_available
                            && (!tagged_response_available || prefer_store_q);
  end : select_response

  always_comb begin : next_state
    table_data_d             = table_data_q;
    table_valid_d            = table_valid_q;
    store_response_count_d   = store_response_count_q;
    store_response_arrivals  = '0;
    output_data_d            = output_data_q;
    output_valid_d           = output_valid_q;
    prefer_store_d           = prefer_store_q;

    for (int p = 0; p < NumPorts; p++) begin
      if (resp_valid_i[p] && resp_ready_o[p]) begin
        if (resp_payload_i[p].id < NumTransactions) begin
          table_data_d[resp_payload_i[p].id][p]  = resp_payload_i[p];
          table_valid_d[resp_payload_i[p].id][p] = 1'b1;
        end else if (resp_payload_i[p].id == NumTransactions) begin
          store_response_arrivals += 1'b1;
        end
      end
    end
    store_response_count_d += store_response_arrivals;

    // Once selected, a response lives in this holding register until every
    // output lane can advance together. Removing its source at selection time
    // prevents both tagged entries and store credits from being emitted twice.
    output_slot_available = !output_valid_q || (&resp_ready_i);
    if (output_slot_available) begin
      output_valid_d = 1'b0;
      if (tagged_response_available || store_response_available) begin
        output_valid_d = 1'b1;
        if (select_store_response) begin
          output_data_d = '0;
          for (int p = 0; p < NumPorts; p++) begin
            output_data_d[p].id = NumTransactions;
          end
          store_response_count_d -= StoreResponsesPerTransaction;
          prefer_store_d = 1'b0;
        end else begin
          output_data_d = table_data_q[selected_transaction];
          table_valid_d[selected_transaction] = '0;
          prefer_store_d = 1'b1;
        end
      end
    end
  end : next_state

  always_ff @(posedge clk_i or negedge rst_ni) begin : state_reg
    if (!rst_ni) begin
      table_data_q           <= '0;
      table_valid_q          <= '0;
      store_response_count_q <= '0;
      output_data_q          <= '0;
      output_valid_q         <= 1'b0;
      prefer_store_q         <= 1'b0;
    end else begin
      table_data_q           <= table_data_d;
      table_valid_q          <= table_valid_d;
      store_response_count_q <= store_response_count_d;
      output_data_q          <= output_data_d;
      output_valid_q         <= output_valid_d;
      prefer_store_q         <= prefer_store_d;
    end
  end : state_reg

  assign resp_ready_o   = '1;
  assign resp_payload_o = output_data_q;
  assign resp_valid_o   = {NumPorts{output_valid_q}};

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : response_assertions
    if (rst_ni) begin
      for (int p = 0; p < NumPorts; p++) begin
        if (resp_valid_i[p] && resp_ready_o[p]) begin
          assert ((resp_payload_i[p].id < NumTransactions) ||
                  (resp_payload_i[p].id == NumTransactions))
            else $error("Transaction response ID is neither tagged nor the store ID");
          if (resp_payload_i[p].id < NumTransactions) begin
            assert (!table_valid_q[resp_payload_i[p].id][p])
              else $error("Transaction response overwrote an occupied table entry");
          end
        end
      end
      if (output_valid_q) begin
        for (int p = 1; p < NumPorts; p++) begin
          assert (output_data_q[p].id == output_data_q[0].id)
            else $error("Wide transaction response contains mismatched IDs");
        end
      end
    end
  end : response_assertions
`endif

  if (NumTransactions < 1) begin: gen_invalid_num_transactions
    $fatal(1, "transactions_table requires at least one tagged transaction");
  end

endmodule
