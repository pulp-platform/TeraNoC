// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// AUTOMATICALLY GENERATED! DO NOT EDIT!

`include "axi/typedef.svh"
`include "floo_noc/typedef.svh"

package floo_terapool_noc_pkg;

  import floo_pkg::*;

  /////////////////////
  //   Address Map   //
  /////////////////////

  typedef enum logic [5:0] {
    GroupX0Y0 = 0,
    GroupX0Y1 = 1,
    GroupX0Y2 = 2,
    GroupX0Y3 = 3,
    GroupX1Y0 = 4,
    GroupX1Y1 = 5,
    GroupX1Y2 = 6,
    GroupX1Y3 = 7,
    GroupX2Y0 = 8,
    GroupX2Y1 = 9,
    GroupX2Y2 = 10,
    GroupX2Y3 = 11,
    GroupX3Y0 = 12,
    GroupX3Y1 = 13,
    GroupX3Y2 = 14,
    GroupX3Y3 = 15,
    Hbm0 = 16,
    Hbm1 = 17,
    Hbm2 = 18,
    Hbm3 = 19,
    Hbm4 = 20,
    Hbm5 = 21,
    Hbm6 = 22,
    Hbm7 = 23,
    Hbm8 = 24,
    Hbm9 = 25,
    Hbm10 = 26,
    Hbm11 = 27,
    Hbm12 = 28,
    Hbm13 = 29,
    Hbm14 = 30,
    Hbm15 = 31,
    Periphs = 32,
    Host = 33,
    NumEndpoints = 34
  } ep_id_e;



  typedef enum logic [4:0] {
    Hbm0SamIdx = 0,
    Hbm1SamIdx = 1,
    Hbm2SamIdx = 2,
    Hbm3SamIdx = 3,
    Hbm4SamIdx = 4,
    Hbm5SamIdx = 5,
    Hbm6SamIdx = 6,
    Hbm7SamIdx = 7,
    Hbm8SamIdx = 8,
    Hbm9SamIdx = 9,
    Hbm10SamIdx = 10,
    Hbm11SamIdx = 11,
    Hbm12SamIdx = 12,
    Hbm13SamIdx = 13,
    Hbm14SamIdx = 14,
    Hbm15SamIdx = 15,
    Periphs1SamIdx = 16,
    Periphs0SamIdx = 17
  } sam_idx_e;



  typedef logic [0:0] rob_idx_t;
  typedef logic [0:0] port_id_t;
  typedef logic [5:0] id_t;
  typedef logic route_t;


  localparam int unsigned SamNumRules = 18;

  typedef struct packed {
    id_t idx;
    logic [31:0] start_addr;
    logic [31:0] end_addr;
  } sam_rule_t;

  localparam sam_rule_t [SamNumRules-1:0] Sam = '{
      '{idx: 32, start_addr: 32'h00000000, end_addr: 32'h7fffffff},  // periphs_0_sam_idx
      '{idx: 32, start_addr: 32'ha0000000, end_addr: 32'hc000ffff},  // periphs_1_sam_idx
      '{idx: 31, start_addr: 32'h80f00000, end_addr: 32'h81000000},  // hbm_15_sam_idx
      '{idx: 30, start_addr: 32'h80e00000, end_addr: 32'h80f00000},  // hbm_14_sam_idx
      '{idx: 29, start_addr: 32'h80d00000, end_addr: 32'h80e00000},  // hbm_13_sam_idx
      '{idx: 28, start_addr: 32'h80c00000, end_addr: 32'h80d00000},  // hbm_12_sam_idx
      '{idx: 27, start_addr: 32'h80b00000, end_addr: 32'h80c00000},  // hbm_11_sam_idx
      '{idx: 26, start_addr: 32'h80a00000, end_addr: 32'h80b00000},  // hbm_10_sam_idx
      '{idx: 25, start_addr: 32'h80900000, end_addr: 32'h80a00000},  // hbm_9_sam_idx
      '{idx: 24, start_addr: 32'h80800000, end_addr: 32'h80900000},  // hbm_8_sam_idx
      '{idx: 23, start_addr: 32'h80700000, end_addr: 32'h80800000},  // hbm_7_sam_idx
      '{idx: 22, start_addr: 32'h80600000, end_addr: 32'h80700000},  // hbm_6_sam_idx
      '{idx: 21, start_addr: 32'h80500000, end_addr: 32'h80600000},  // hbm_5_sam_idx
      '{idx: 20, start_addr: 32'h80400000, end_addr: 32'h80500000},  // hbm_4_sam_idx
      '{idx: 19, start_addr: 32'h80300000, end_addr: 32'h80400000},  // hbm_3_sam_idx
      '{idx: 18, start_addr: 32'h80200000, end_addr: 32'h80300000},  // hbm_2_sam_idx
      '{idx: 17, start_addr: 32'h80100000, end_addr: 32'h80200000},  // hbm_1_sam_idx
      '{idx: 16, start_addr: 32'h80000000, end_addr: 32'h80100000}  // hbm_0_sam_idx

  };



  localparam route_cfg_t RouteCfg = '{
      RouteAlgo: IdTable,
      UseIdTable: 1'b1,
      XYAddrOffsetX: 0,
      XYAddrOffsetY: 0,
      IdAddrOffset: 0,
      NumSamRules: 18,
      NumRoutes: 0
  };


  typedef logic [31:0] axi_narrow_in_addr_t;
  typedef logic [63:0] axi_narrow_in_data_t;
  typedef logic [7:0] axi_narrow_in_strb_t;
  typedef logic [0:0] axi_narrow_in_id_t;
  typedef logic [0:0] axi_narrow_in_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_narrow_in, axi_narrow_in_req_t, axi_narrow_in_rsp_t, axi_narrow_in_addr_t,
                      axi_narrow_in_id_t, axi_narrow_in_data_t, axi_narrow_in_strb_t,
                      axi_narrow_in_user_t)


  typedef logic [31:0] axi_narrow_out_addr_t;
  typedef logic [63:0] axi_narrow_out_data_t;
  typedef logic [7:0] axi_narrow_out_strb_t;
  typedef logic [0:0] axi_narrow_out_id_t;
  typedef logic [0:0] axi_narrow_out_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_narrow_out, axi_narrow_out_req_t, axi_narrow_out_rsp_t,
                      axi_narrow_out_addr_t, axi_narrow_out_id_t, axi_narrow_out_data_t,
                      axi_narrow_out_strb_t, axi_narrow_out_user_t)


  typedef logic [31:0] axi_wide_in_addr_t;
  typedef logic [511:0] axi_wide_in_data_t;
  typedef logic [63:0] axi_wide_in_strb_t;
  typedef logic [1:0] axi_wide_in_id_t;
  typedef logic [0:0] axi_wide_in_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_wide_in, axi_wide_in_req_t, axi_wide_in_rsp_t, axi_wide_in_addr_t,
                      axi_wide_in_id_t, axi_wide_in_data_t, axi_wide_in_strb_t, axi_wide_in_user_t)


  typedef logic [31:0] axi_wide_out_addr_t;
  typedef logic [511:0] axi_wide_out_data_t;
  typedef logic [63:0] axi_wide_out_strb_t;
  typedef logic [1:0] axi_wide_out_id_t;
  typedef logic [0:0] axi_wide_out_user_t;
  `AXI_TYPEDEF_ALL_CT(axi_wide_out, axi_wide_out_req_t, axi_wide_out_rsp_t, axi_wide_out_addr_t,
                      axi_wide_out_id_t, axi_wide_out_data_t, axi_wide_out_strb_t,
                      axi_wide_out_user_t)



  `FLOO_TYPEDEF_HDR_T(hdr_t, id_t, id_t, nw_ch_e, rob_idx_t)
  localparam axi_cfg_t AxiCfgN = '{
      AddrWidth: 32,
      DataWidth: 64,
      UserWidth: 1,
      InIdWidth: 1,
      OutIdWidth: 1
  };
  localparam axi_cfg_t AxiCfgW = '{
      AddrWidth: 32,
      DataWidth: 512,
      UserWidth: 1,
      InIdWidth: 2,
      OutIdWidth: 2
  };
  `FLOO_TYPEDEF_NW_CHAN_ALL(axi, req, rsp, wide, axi_narrow_in, axi_wide_in, AxiCfgN, AxiCfgW,
                            hdr_t)

  `FLOO_TYPEDEF_NW_LINK_ALL(req, rsp, wide, req, rsp, wide)


endpackage
