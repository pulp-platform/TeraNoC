// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

package mempool_pkg;

  import snitch_pkg::MetaIdWidth;
  import cf_math_pkg::idx_width;

  /*********************
   *  TILE PARAMETERS  *
   *********************/

  `include "axi/assign.svh"
  `include "axi/typedef.svh"

  localparam integer unsigned NumCores                = `ifdef NUM_CORES `NUM_CORES `else 0 `endif;
  localparam integer unsigned NumCoresPerTile         = `ifdef NUM_CORES_PER_TILE `NUM_CORES_PER_TILE `else 0 `endif;
  localparam integer unsigned NumDivsqrtPerTile       = `ifdef NUM_DIVSQRT_PER_TILE `NUM_DIVSQRT_PER_TILE `else (snitch_pkg::XDIVSQRT) `endif;
  localparam integer unsigned NumGroups               = `ifdef NUM_GROUPS `NUM_GROUPS `else 0 `endif;
  localparam integer unsigned MAX_NumGroups           = 64;
  localparam integer unsigned RemoteGroupLatencyCycle = `ifdef REMOTE_GROUP_LATENCY_CYCLES `REMOTE_GROUP_LATENCY_CYCLES `else 7 `endif;
  localparam integer unsigned NumTiles                = NumCores / NumCoresPerTile;
  localparam integer unsigned NumTilesPerGroup        = NumTiles / NumGroups;
  localparam integer unsigned NumCoresPerGroup        = NumCores / NumGroups;
  localparam integer unsigned NumCoresPerCache        = NumCoresPerTile;
  localparam integer unsigned AxiCoreIdWidth          = 1;
  localparam integer unsigned AxiTileIdWidth          = AxiCoreIdWidth+1; // + 1 for cache
  localparam integer unsigned AxiDataWidth            = `ifdef AXI_DATA_WIDTH `AXI_DATA_WIDTH `else 0 `endif;
  localparam integer unsigned AxiLiteDataWidth        = 32;

  // Extension support
  localparam bit RVV        = `ifdef RVV `RVV `else 0 `endif;
  localparam bit RVF        = `ifdef RVF `RVF `else 0 `endif;
  // RVD is not supported for MemPool family
  localparam bit RVD        = 0;
  localparam bit XFVEC      = 0;
  localparam bit XFDOTP     = RVF ? 1 : 0;
  localparam bit XFAUX      = 0;
  localparam bit XF16       = RVF ? 1 : 0;
  localparam bit XF16ALT    = 1;
  localparam bit XF8        = RVF ? 1 : 0;
  localparam bit XF8ALT     = 0;
  /// Enable div/sqrt unit (buggy - use with caution)
  localparam bit XDivSqrt   = 0;

  // Derived parameters
  localparam integer unsigned NumIPUsPerCore      = `ifdef N_IPU `N_IPU `else 1 `endif;
  localparam integer unsigned NumFPUsPerCore      = `ifdef N_FPU `N_FPU `else 1 `endif;
  localparam integer unsigned NumFUsPerCore       = NumIPUsPerCore > NumFPUsPerCore ? NumIPUsPerCore : NumFPUsPerCore;
  localparam integer unsigned NumFUsPerTile       = NumFUsPerCore * NumCoresPerTile;
  localparam integer unsigned NumMemPortsPerSpatz = NumFUsPerCore;
  localparam integer unsigned NumDataPortsPerCore = 1 + RVV*NumMemPortsPerSpatz;


  /***********************
   *  MEMORY PARAMETERS  *
   ***********************/
  // Element widths
  localparam integer unsigned XLEN = 32; // Snitch always operates on 32 bit integers
  localparam integer unsigned FLEN = 32;
  localparam integer unsigned ELEN = 32;

  localparam integer unsigned AddrWidth        = 32;
  localparam integer unsigned DataWidth        = 32;
  localparam integer unsigned BeWidth          = DataWidth / 8;
  localparam integer unsigned ByteOffset       = $clog2(BeWidth);
  localparam integer unsigned BankingFactor    = `ifdef BANKING_FACTOR `BANKING_FACTOR `else 0 `endif;
  localparam bit              LrScEnable       = 1'b1;
  localparam integer unsigned TCDMSizePerBank  = `ifdef L1_BANK_SIZE `L1_BANK_SIZE `else 0 `endif;
  localparam integer unsigned NumBanks         = NumCores * NumFUsPerCore * BankingFactor;
  localparam integer unsigned NumBanksPerTile  = NumBanks / NumTiles;
  localparam integer unsigned NumBanksPerGroup = NumBanks / NumGroups;
  localparam integer unsigned TCDMAddrMemWidth = $clog2(TCDMSizePerBank / mempool_pkg::BeWidth);
  localparam integer unsigned TCDMAddrWidth    = TCDMAddrMemWidth + idx_width(NumBanksPerGroup);

  // L2
  localparam integer unsigned L2Size           = `ifdef L2_SIZE `L2_SIZE `else 0 `endif; // [B]
  localparam integer unsigned NumL2Banks       = `ifdef L2_BANKS `L2_BANKS `else 1 `endif;
  // Off-cluster AXI channels on the mesh perimeter. Equal to the L2 bank count,
  // since gen_l2_adapters wires master i to bank i. This is NOT NumGroups: the
  // perimeter holds 2*(NumX+NumY) attachment points while there are NumX*NumY
  // groups, and those coincide only at 4x4. See docs/scaleup/mesh_plan.md 12.
  localparam integer unsigned NumL2Channels   = NumL2Banks;
  localparam integer unsigned L2BankSize       = L2Size / NumL2Banks;
  localparam integer unsigned L2BankWidth      = AxiDataWidth;
  localparam integer unsigned L2BankBeWidth    = L2BankWidth/8;
  localparam integer unsigned L2BankNumWords   = L2BankSize / L2BankBeWidth;
  localparam integer unsigned L2BankAddrWidth  = $clog2(L2BankNumWords);
  localparam integer unsigned L2Width          = L2BankWidth * NumL2Banks;
  localparam integer unsigned L2BeWidth        = L2Width/8;
  localparam integer unsigned L2ByteOffset     = $clog2(L2BeWidth);
  localparam integer unsigned L2AddrWidth      = $clog2(L2Size);
  localparam integer unsigned Interleave       = `ifdef AXI_WIDTH_INTERLEAVED `AXI_WIDTH_INTERLEAVED `else 16 `endif;
  localparam integer unsigned L2BankByteOffset = $clog2(L2BankBeWidth);

  typedef logic [AxiCoreIdWidth-1:0    ] axi_core_id_t;
  typedef logic [AxiTileIdWidth-1:0    ] axi_tile_id_t;
  typedef logic [AxiDataWidth-1:0      ] axi_data_t;
  typedef logic [AxiDataWidth/8-1:0    ] axi_strb_t;
  typedef logic [AxiLiteDataWidth-1:0  ] axi_lite_data_t;
  typedef logic [AxiLiteDataWidth/8-1:0] axi_lite_strb_t;
  typedef logic [AddrWidth-1:0         ] addr_t;
  typedef logic [DataWidth-1:0         ] data_t;
  typedef logic [BeWidth-1:0           ] strb_t;

  `ifdef DRAM
    localparam integer unsigned NumDrams         = `ifdef L2_BANKS `L2_BANKS `else 1 `endif;
    localparam integer unsigned L2DramWidth      = AxiDataWidth;
    localparam integer unsigned L2DramBeWidth    = L2DramWidth/8;
    localparam integer unsigned L2DramByteOffset = $clog2(L2DramBeWidth);

    // DRAM Interleaving Functions
    typedef struct packed {
      int                   dram_ctrl_id;
      logic [AddrWidth-1:0] dram_ctrl_addr;
    } dram_ctrl_interleave_t;

    function automatic dram_ctrl_interleave_t getDramCTRLInfo(addr_t addr);
      automatic dram_ctrl_interleave_t res;
      localparam int unsigned ConstantBits = $clog2(L2DramBeWidth * Interleave);
      localparam int unsigned ScrambleBits = (NumDrams == 1) ? 1 : $clog2(NumDrams);
      localparam int unsigned ReminderBits = AddrWidth - ScrambleBits - ConstantBits;
      automatic addr_t reminder_addr = addr[AddrWidth-1: AddrWidth-ReminderBits];

      res.dram_ctrl_id = addr[ScrambleBits + ConstantBits - 1: ConstantBits];
      res.dram_ctrl_addr = {reminder_addr, addr[ConstantBits-1:0]};
      return res;
    endfunction
  `else
    // SRAM Interleaving Functions
    typedef struct packed {
      int                   sram_ctrl_id;
      logic [AddrWidth-1:0] sram_ctrl_addr;
    } sram_ctrl_interleave_t;

    function automatic sram_ctrl_interleave_t getSramCTRLInfo(addr_t addr);
      automatic sram_ctrl_interleave_t res;
      localparam int unsigned ConstantBits = $clog2(L2BankBeWidth * Interleave);
      localparam int unsigned ScrambleBits = (NumL2Banks == 1) ? 1 : $clog2(NumL2Banks);
      localparam int unsigned ReminderBits = AddrWidth - ScrambleBits - ConstantBits;
      automatic addr_t reminder_addr = addr[AddrWidth-1: AddrWidth-ReminderBits];

      res.sram_ctrl_id = addr[ScrambleBits + ConstantBits - 1: ConstantBits];
      if (Interleave == 1) begin
        res.sram_ctrl_addr = addr[AddrWidth-1: L2BankByteOffset + ScrambleBits];
      end else begin
        res.sram_ctrl_addr = { addr[AddrWidth-1: AddrWidth-ReminderBits], addr[ConstantBits-1: L2BankByteOffset] };
      end
      return res;
    endfunction
  `endif

  localparam NumSystemXbarMasters = 1;
  localparam AxiSystemIdWidth = $clog2(NumSystemXbarMasters) + AxiTileIdWidth;
  typedef logic [AxiSystemIdWidth-1:0] axi_system_id_t;

  localparam NumTestbenchXbarMasters = 1;
  localparam AxiTestbenchIdWidth = $clog2(NumTestbenchXbarMasters) + AxiSystemIdWidth;
  typedef logic [AxiTestbenchIdWidth-1:0] axi_tb_id_t;

  `AXI_TYPEDEF_AW_CHAN_T(axi_core_aw_t, addr_t, axi_core_id_t, logic);
  `AXI_TYPEDEF_W_CHAN_T(axi_core_w_t, axi_data_t, axi_strb_t, logic);
  `AXI_TYPEDEF_B_CHAN_T(axi_core_b_t, axi_core_id_t, logic);
  `AXI_TYPEDEF_AR_CHAN_T(axi_core_ar_t, addr_t, axi_core_id_t, logic);
  `AXI_TYPEDEF_R_CHAN_T(axi_core_r_t, axi_data_t, axi_core_id_t, logic);
  `AXI_TYPEDEF_REQ_T(axi_core_req_t, axi_core_aw_t, axi_core_w_t, axi_core_ar_t);
  `AXI_TYPEDEF_RESP_T(axi_core_resp_t, axi_core_b_t, axi_core_r_t );

  `AXI_TYPEDEF_AW_CHAN_T(axi_tile_aw_t, addr_t, axi_tile_id_t, logic);
  `AXI_TYPEDEF_W_CHAN_T(axi_tile_w_t, axi_data_t, axi_strb_t, logic);
  `AXI_TYPEDEF_B_CHAN_T(axi_tile_b_t, axi_tile_id_t, logic);
  `AXI_TYPEDEF_AR_CHAN_T(axi_tile_ar_t, addr_t, axi_tile_id_t, logic);
  `AXI_TYPEDEF_R_CHAN_T(axi_tile_r_t, axi_data_t, axi_tile_id_t, logic);
  `AXI_TYPEDEF_REQ_T(axi_tile_req_t, axi_tile_aw_t, axi_tile_w_t, axi_tile_ar_t);
  `AXI_TYPEDEF_RESP_T(axi_tile_resp_t, axi_tile_b_t, axi_tile_r_t );

  `AXI_TYPEDEF_AW_CHAN_T(axi_system_aw_t, addr_t, axi_system_id_t, logic);
  `AXI_TYPEDEF_W_CHAN_T(axi_system_w_t, axi_data_t, axi_strb_t, logic);
  `AXI_TYPEDEF_B_CHAN_T(axi_system_b_t, axi_system_id_t, logic);
  `AXI_TYPEDEF_AR_CHAN_T(axi_system_ar_t, addr_t, axi_system_id_t, logic);
  `AXI_TYPEDEF_R_CHAN_T(axi_system_r_t, axi_data_t, axi_system_id_t, logic);
  `AXI_TYPEDEF_REQ_T(axi_system_req_t, axi_system_aw_t, axi_system_w_t, axi_system_ar_t);
  `AXI_TYPEDEF_RESP_T(axi_system_resp_t, axi_system_b_t, axi_system_r_t);

  // AXI to periph
  `AXI_TYPEDEF_W_CHAN_T(axi_periph_w_t, axi_lite_data_t, axi_lite_strb_t, logic);
  `AXI_TYPEDEF_R_CHAN_T(axi_periph_r_t, axi_lite_data_t, axi_system_id_t, logic);
  `AXI_TYPEDEF_REQ_T(axi_periph_req_t, axi_system_aw_t, axi_periph_w_t, axi_system_ar_t);
  `AXI_TYPEDEF_RESP_T(axi_periph_resp_t, axi_system_b_t, axi_periph_r_t);

  `AXI_TYPEDEF_AW_CHAN_T(axi_tb_aw_t, addr_t, axi_tb_id_t, logic);
  `AXI_TYPEDEF_W_CHAN_T(axi_tb_w_t, axi_data_t, axi_strb_t, logic);
  `AXI_TYPEDEF_B_CHAN_T(axi_tb_b_t, axi_tb_id_t, logic);
  `AXI_TYPEDEF_AR_CHAN_T(axi_tb_ar_t, addr_t, axi_tb_id_t, logic);
  `AXI_TYPEDEF_R_CHAN_T(axi_tb_r_t, axi_data_t, axi_tb_id_t, logic);
  `AXI_TYPEDEF_REQ_T(axi_tb_req_t, axi_tb_aw_t, axi_tb_w_t, axi_tb_ar_t);
  `AXI_TYPEDEF_RESP_T(axi_tb_resp_t, axi_tb_b_t, axi_tb_r_t);

  `AXI_LITE_TYPEDEF_AW_CHAN_T(axi_lite_slv_aw_t, addr_t)
  `AXI_LITE_TYPEDEF_W_CHAN_T(axi_lite_slv_w_t, axi_lite_data_t, axi_lite_strb_t)
  `AXI_LITE_TYPEDEF_B_CHAN_T(axi_lite_slv_b_t)
  `AXI_LITE_TYPEDEF_AR_CHAN_T(axi_lite_slv_ar_t, addr_t)
  `AXI_LITE_TYPEDEF_R_CHAN_T(axi_lite_slv_r_t, axi_lite_data_t)
  `AXI_LITE_TYPEDEF_REQ_T(axi_lite_slv_req_t, axi_lite_slv_aw_t, axi_lite_slv_w_t, axi_lite_slv_ar_t)
  `AXI_LITE_TYPEDEF_RESP_T(axi_lite_slv_resp_t, axi_lite_slv_b_t, axi_lite_slv_r_t)

  /***********************
   *  INSTRUCTION CACHE  *
   ***********************/

  localparam int unsigned ICacheSizeByte  = 512 * NumFUsPerTile * NumCoresPerCache;      // Total Size of instruction cache in bytes
  localparam int unsigned ICacheSets      = NumFUsPerTile * NumCoresPerCache / 2;        // Number of sets (it is actually the way)
  localparam int unsigned ICacheLineWidth = 32 * 2 * NumFUsPerTile * NumCoresPerCache;   // Size of each cache line in bits
  /*********************
   *  READ-ONLY CACHE  *
   *********************/

  localparam int unsigned AxiHierRadix      = `ifdef AXI_HIER_RADIX `AXI_HIER_RADIX `else NumTilesPerGroup `endif;
  localparam int unsigned ROCacheLineWidth  = `ifdef RO_LINE_WIDTH `RO_LINE_WIDTH `else ICacheLineWidth `endif;
  localparam int unsigned ROCacheSizeByte   = 8192;
  localparam int unsigned ROCacheSets       = 2;

  localparam int unsigned ROCacheNumAddrRules = 4;
  typedef struct packed {
    logic enable;
    logic flush_valid;
    logic [ROCacheNumAddrRules-1:0][AddrWidth-1:0] start_addr;
    logic [ROCacheNumAddrRules-1:0][AddrWidth-1:0] end_addr;
  } ro_cache_ctrl_t;

  // RO cache reset value to avoid fatal warnings during reset in the address decoder
  localparam ro_cache_ctrl_t ro_cache_ctrl_default = '{
    enable: '0,
    flush_valid: '0,
    start_addr: {32'h18,32'h10,32'h08,32'h00},
    end_addr: {32'h1C,32'h14,32'h0C,32'h04}
  };

  /*********
   *  DMA  *
   *********/

  localparam int unsigned NumDmasPerGroup       = `ifdef DMAS_PER_GROUP `DMAS_PER_GROUP `else 4 `endif;
  localparam int unsigned NumTilesPerDma        = NumTilesPerGroup/NumDmasPerGroup;
  localparam int unsigned DmaDataWidth          = AxiDataWidth;
  localparam int unsigned DmaNumWords           = DmaDataWidth/DataWidth;
  localparam int unsigned NumSuperbanks         = NumBanksPerTile/DmaNumWords;
  localparam int unsigned DmaBurstLen           = (NumBanksPerGroup / NumDmasPerGroup) / DmaNumWords;
  localparam int unsigned NumAXIMastersPerGroup = `ifdef AXI_MASTERS_PER_GROUP `AXI_MASTERS_PER_GROUP `else 1 `endif;

  typedef logic [DmaNumWords*DataWidth-1:0] dma_data_t;
  typedef logic [DmaNumWords*DataWidth/8-1:0] dma_strb_t;

  typedef struct packed {
    axi_tile_id_t id;
    addr_t src;
    addr_t dst;
    logic [31:0] num_bytes;
    axi_pkg::cache_t cache_src;
    axi_pkg::cache_t cache_dst;
    axi_pkg::burst_t burst_src;
    axi_pkg::burst_t burst_dst;
    logic decouple_rw;
    logic deburst;
    logic serialize;
  } dma_req_t;

  typedef struct packed {
    logic backend_idle;
    logic trans_complete;
  } dma_meta_t;

  /**********************************
   *  TCDM INTERCONNECT PARAMETERS  *
   **********************************/

  typedef logic [TCDMAddrWidth-1:0] tcdm_addr_t;
  typedef logic [TCDMAddrMemWidth-1:0] bank_addr_t;
  typedef logic [TCDMAddrMemWidth+idx_width(NumBanksPerTile)-1:0] tile_addr_t;
  typedef logic [MetaIdWidth-1:0] meta_id_t;
  typedef logic [idx_width(NumCoresPerTile * NumDataPortsPerCore)-1:0] tile_core_id_t;
  typedef logic [idx_width(NumTilesPerGroup)-1:0] tile_group_id_t;
  typedef logic [idx_width(NumGroups)-1:0] group_id_t;
  typedef logic [3:0] amo_t;
  localparam int unsigned MaxBurstWords = 16;
  localparam int unsigned BurstLenWidth = $clog2(MaxBurstWords + 1);

  // Group-MSHR response tag (Tier-b response routing): the group MSHR stamps each remote request
  // with its allocated entry id so the returning response can index the entry directly (O(1))
  // instead of scanning all entries. Width must match mempool_group_mshr's MshrNum (driven by the
  // same GROUP_MSHR_NUM macro, defaulting to NumTilesPerGroup).
  localparam int unsigned MshrTagNum   = `ifdef GROUP_MSHR_NUM `GROUP_MSHR_NUM `else NumTilesPerGroup `endif;
  // +1 so tag value 0 is a reserved "no MSHR entry" sentinel (bypass / store / non-mergeable); a real
  // entry id e is carried as (e+1). The response path uses this to tell MSHR-routed beats from bypass.
  localparam int unsigned MshrTagWidth = idx_width(MshrTagNum + 1);

  typedef struct packed {
    meta_id_t meta_id;
    tile_core_id_t core_id;
    amo_t amo;
    data_t data;
  } tcdm_payload_t;

  typedef struct packed {
    tcdm_payload_t wdata;
    logic wen;
    strb_t be;
    group_id_t tgt_group_id; // FlooNoC Added
    tcdm_addr_t tgt_addr;
    logic [BurstLenWidth-1:0] burst_len;
    logic [MshrTagWidth-1:0] mshr_tag; // Tier-b: MSHR entry id stamped at allocation
  } tcdm_master_req_t;

  typedef struct packed {
    tcdm_payload_t rdata;
    logic wen;               // Spatz Added
    logic [MshrTagWidth-1:0] mshr_tag; // Tier-b: echoed MSHR entry id for direct response routing
  } tcdm_master_resp_t;

  typedef struct packed {
    tcdm_payload_t wdata;
    logic wen;
    strb_t be;
    tile_addr_t tgt_addr;
    tile_group_id_t ini_addr;
    group_id_t src_group_id; // FlooNoC Added
    logic [BurstLenWidth-1:0] burst_len;
    logic [MshrTagWidth-1:0] mshr_tag; // Tier-b: requester MSHR entry id, echoed by the slave
  } tcdm_slave_req_t;

  typedef struct packed {
    tcdm_payload_t rdata;
    tile_group_id_t ini_addr;
    group_id_t src_group_id; // FlooNoC Added
    logic wen;               // Spatz Added
    logic [MshrTagWidth-1:0] mshr_tag; // Tier-b: echoed MSHR entry id
  } tcdm_slave_resp_t;

  /********************
   *  DMA PARAMETERS  *
   *******************/

  typedef struct packed {
    meta_id_t meta_id;
    tile_core_id_t core_id;
    amo_t amo;
    dma_data_t data;
  } dma_payload_t;

  typedef struct packed {
    dma_payload_t wdata;
    logic wen;
    dma_strb_t be;
    tile_addr_t tgt_addr;
  } tcdm_dma_req_t;

  typedef struct packed {
    dma_payload_t rdata;
  } tcdm_dma_resp_t;

  /*************************************
   *  FlooNoC INTERCONNECT PARAMETERS  *
   *************************************/

  // FlooNoC parameters
  localparam integer unsigned NumRdRemoteReqPortsPerTile   = `ifdef NOC_REQ_RD_CHANNEL_NUM   `NOC_REQ_RD_CHANNEL_NUM   `else 0 `endif;
  localparam integer unsigned NumRdWrRemoteReqPortsPerTile = `ifdef NOC_REQ_RDWR_CHANNEL_NUM `NOC_REQ_RDWR_CHANNEL_NUM `else 2 `endif;
  localparam integer unsigned NumWrRemoteReqPortsPerTile   = `ifdef NOC_REQ_WR_CHANNEL_NUM   `NOC_REQ_WR_CHANNEL_NUM   `else 0 `endif;

  localparam integer unsigned NumNarrowRemoteReqPortsPerTile = NumRdRemoteReqPortsPerTile;
  localparam integer unsigned NumWideRemoteReqPortsPerTile   = NumRdWrRemoteReqPortsPerTile + NumWrRemoteReqPortsPerTile;

  localparam integer unsigned NumRemoteReqPortsPerTile     = 1 + NumNarrowRemoteReqPortsPerTile + NumWideRemoteReqPortsPerTile;
  localparam integer unsigned NumRemoteRespPortsPerTile    = 1 + (`ifdef NOC_RESP_CHANNEL_NUM `NOC_RESP_CHANNEL_NUM `else 2 `endif);
  localparam integer unsigned NumDirections = `ifdef NUM_DIRECTIONS `NUM_DIRECTIONS `else 5 `endif;
  localparam integer unsigned NumX = `ifdef NUM_X `NUM_X `else 2 `endif;
  localparam integer unsigned NumY = NumGroups/NumX;
  localparam integer unsigned NocTopology = `ifdef NOC_TOPOLOGY `NOC_TOPOLOGY `else 0 `endif;
  localparam integer unsigned NocRoutingAlgorithm = `ifdef NOC_ROUTING_ALGORITHM `NOC_ROUTING_ALGORITHM `else 0 `endif;
  localparam integer unsigned NocRouterRemapping = `ifdef NOC_ROUTER_REMAPPING `NOC_ROUTER_REMAPPING `else 0 `endif;
  // Hash-based port spreading at tile level (bit 0 = req, bit 1 = resp).
  localparam integer unsigned NocPortHash = `ifdef NOC_PORT_HASH `NOC_PORT_HASH `else 0 `endif;
  // router buffer configuration
  localparam integer unsigned NumRouterInFifoDepth  = `ifdef NOC_ROUTER_INPUT_FIFO_DEP   `NOC_ROUTER_INPUT_FIFO_DEP   `else 2 `endif;
  localparam integer unsigned NumRouterOutFifoDepth = `ifdef NOC_ROUTER_OUTPUT_FIFO_DEP  `NOC_ROUTER_OUTPUT_FIFO_DEP  `else 2 `endif;
  localparam integer unsigned SpmBankIdRemap = `ifdef SPM_BANK_ID_REMAP `SPM_BANK_ID_REMAP `else 0 `endif;
  localparam integer unsigned TileIdRemap = `ifdef TILE_ID_REMAP `TILE_ID_REMAP `else 0 `endif;
  localparam integer unsigned RouterRemapGroupSize = `ifdef NOC_ROUTER_REMAP_GROUP_SIZE `NOC_ROUTER_REMAP_GROUP_SIZE `else 2 `endif;

  // FlooNoC group id types for XY routing.
  //
  // x and y are sized INDEPENDENTLY from NumX and NumY. The previous form gave
  // both idx_width(NumGroups)/2, which is exact only when idx_width(NumGroups) is
  // even -- 4, 16, 64, 256 groups -- and is SILENTLY too narrow otherwise: at 32
  // groups it yields 2 bits per axis for an 8-wide axis. Bit-identical at 4x4,
  // where idx_width(4) == idx_width(16)/2 == 2.
  //
  // The widths must SUM to idx_width(NumGroups), not merely be wide enough: the
  // mesh coordinate is never computed, it is BIT-CAST from the flat group id
  // (group_xy_id_t'({tgt_group_id, 1'b0}) in mempool_group_floonoc_wrapper), so a
  // mismatched sum mis-splits x from y instead of failing. The cluster wrappers
  // assert that identity at elaboration.
  typedef struct packed {
    logic [idx_width(NumX)-1:0] x;
    logic [idx_width(NumY)-1:0] y;
    logic                       port_id;
  } group_xy_id_t;

  // FlooNoC req types
  typedef struct packed {
    amo_t               amo;
    logic               wen;
    strb_t              be;
    data_t              data;
  } floo_tcdm_req_payload_t;

  typedef struct packed {
    meta_id_t           meta_id;
    tile_core_id_t      core_id;
    tile_group_id_t     src_tile_id;
    group_xy_id_t       src_id;
    group_xy_id_t       dst_id;
    tcdm_addr_t         tgt_addr;
    logic               last;
    logic [BurstLenWidth-1:0] burst_len;
    logic [MshrTagWidth-1:0]  mshr_tag; // Tier-b: requester MSHR entry id (NoC req header)
  } floo_tcdm_req_meta_t;

  typedef struct packed {
    floo_tcdm_req_meta_t  hdr;
  } floo_tcdm_rd_req_t;

  typedef struct packed {
    floo_tcdm_req_payload_t payload;
    floo_tcdm_req_meta_t    hdr;
  } floo_tcdm_rdwr_req_t;

  `ifndef USE_NARROW_REQ_CHANNEL
    typedef struct packed {
      floo_tcdm_rdwr_req_t req;
      logic                valid;
      logic                ready;
    } floo_tcdm_req_if_wide_entry_t;

    typedef struct packed {
      floo_tcdm_req_if_wide_entry_t     [NumWideRemoteReqPortsPerTile-1:0]    wide_req;
    } floo_tcdm_req_if_per_tile_entry_t;

    typedef struct packed {
      floo_tcdm_req_if_per_tile_entry_t [NumTilesPerGroup-1:0] floo_tcdm_req;
    } floo_tcdm_req_if_t;
  `else
    typedef struct packed {
      floo_tcdm_rd_req_t req;
      logic              valid;
      logic              ready;
    } floo_tcdm_req_if_narrow_entry_t;

    typedef struct packed {
      floo_tcdm_rdwr_req_t req;
      logic                valid;
      logic                ready;
    } floo_tcdm_req_if_wide_entry_t;

    typedef struct packed {
      floo_tcdm_req_if_narrow_entry_t   [NumNarrowRemoteReqPortsPerTile-1:0]  narrow_req;
      floo_tcdm_req_if_wide_entry_t     [NumWideRemoteReqPortsPerTile-1:0]    wide_req;
    } floo_tcdm_req_if_per_tile_entry_t;

    typedef struct packed {
      floo_tcdm_req_if_per_tile_entry_t  [NumTilesPerGroup-1:0] floo_tcdm_req;
    } floo_tcdm_req_if_t;
  `endif

  // FlooNoC resp types
  typedef struct packed {
    amo_t               amo;
    data_t              data;
    logic               wen;    // Spatz added
  } floo_tcdm_resp_payload_t;

  typedef struct packed {
    meta_id_t           meta_id;
    tile_core_id_t      core_id;
    tile_group_id_t     tile_id;
    group_xy_id_t       src_id;
    group_xy_id_t       dst_id;
    logic               last;
    logic [MshrTagWidth-1:0]  mshr_tag; // Tier-b: echoed MSHR entry id (NoC resp header)
  } floo_tcdm_resp_meta_t;

  typedef struct packed {
    floo_tcdm_resp_payload_t payload;
    floo_tcdm_resp_meta_t    hdr;
  } floo_tcdm_resp_t;

  typedef struct packed {
    floo_tcdm_resp_t resp;
    logic            valid;
    logic            ready;
  } floo_tcdm_rsp_if_entry_t;

  typedef struct packed {
    floo_tcdm_rsp_if_entry_t     [NumTilesPerGroup-1:0][NumRemoteRespPortsPerTile-1:1]    floo_tcdm_resp;
  } floo_tcdm_rsp_if_t;

  /**********************
   *  QUEUE PARAMETERS  *
   **********************/

  // Size of xqueues in words (must be a power of two)
  localparam int unsigned XQueueSize = `ifdef XQUEUE_SIZE `XQUEUE_SIZE `else 0 `endif;

  /*****************
   *  ADDRESS MAP  *
   *****************/

  // TCDM Memory Region
  localparam addr_t TCDMSize = NumBanks * TCDMSizePerBank;
  localparam addr_t TCDMMask = ~(TCDMSize - 1);

  // Size in bytes of memory that is sequentially addressable per tile
  localparam int unsigned SeqMemSizePerCore = `ifdef SEQ_MEM_SIZE `SEQ_MEM_SIZE `else 0 `endif;
  localparam int unsigned SeqMemSizePerTile = NumCoresPerTile*SeqMemSizePerCore;

  typedef struct packed {
    int unsigned slave_idx;
    addr_t mask;
    addr_t value;
  } address_map_t;

  /***********************
   *  TRAFFIC GENERATOR  *
   ***********************/

  // Replaces core with a traffic generator
  parameter bit TrafficGeneration  = `ifdef TRAFFIC_GEN `TRAFFIC_GEN `else 0 `endif;

  //TeraPool Parameters
  `include "reqrsp_interface/typedef.svh"
  `REQRSP_TYPEDEF_ALL(reqrsp, addr_t, axi_data_t, axi_strb_t)

  // TeraPool PostLayout Control
  localparam bit PostLayoutGr = `ifdef POSTLAYOUTGR `POSTLAYOUTGR `else 0 `endif;

`ifndef TARGET_SYNTHESIS
  `ifndef TARGET_VERILATOR
  // tcdm memory pattern profile
  typedef struct {
    int unsigned initiated;
    int unsigned initial_cycle;
    int unsigned last_read_cycle;
    int unsigned last_write_cycle;
    int unsigned last_access_cycle;
    int unsigned access_read_number;
    int unsigned access_write_number;
    int unsigned access_number;
    int unsigned read_cycles[$];       // dynamic array to store cycles of read accesses
    int unsigned write_cycles[$];      // dynamic array to store cycles of write accesses
  } profile_t;

  // tile level profiling
  typedef struct {
    // tile remote ports profile
    int unsigned req_vld_cyc_num[NumRemoteReqPortsPerTile-1];
    int unsigned req_hsk_cyc_num[NumRemoteReqPortsPerTile-1];
  } tile_level_profile_t;

  // group level profiling
  typedef struct {
    // group xbar ports profile
    int unsigned req_vld_cyc_num                            [NumRemoteReqPortsPerTile-1];
    int unsigned req_hsk_cyc_num                            [NumRemoteReqPortsPerTile-1];
    int unsigned req_vld_cyc_more_than_one_hit_same_bank_num;
  } group_level_profile_t;

  // router level profile
  typedef struct {
    // noc router ports profile
    int unsigned in_vld_cyc_num [4]; // 4: 4 directions
    int unsigned in_hsk_cyc_num [4]; // 4: 4 directions
    int unsigned out_vld_cyc_num[4]; // 4: 4 directions
    int unsigned out_hsk_cyc_num[4]; // 4: 4 directions
  } router_level_profile_t;

  // router local ports profile
    // noc router local req ports profile
  typedef struct {
    int unsigned read_req_num;
    int unsigned write_req_num;
  } router_local_req_port_profile_t;
    // noc router local resp ports profile
  typedef struct {
    int unsigned req_num;
  } router_local_resp_port_profile_t;

  typedef struct {
    // noc router ports profile
    int unsigned in_vld_cyc_num [5];
    int unsigned in_hsk_cyc_num [5];
    int unsigned hol_stall_cyc_num [5];
    int unsigned out_congst_cyc_num [5][5];
    int unsigned cur_stall_cyc_num [5];
    int unsigned max_stall_cyc_num [5];
  } router_input_profile_t;
  `endif
`endif


  /**********************************
   *  GROUP MSHR RUNTIME CONFIG     *
   **********************************/
  // Software-writable group MSHR configuration (docs/mshr_runtime_csr_design.md). Written through
  // the group-barrier port's unused op encoding (bank field == 3), so no new address space and no
  // new crossbar decode. One instance per group.
  //
  // Only knobs that are COMPARE OPERANDS or SHIFT AMOUNTS are here. Anything that sizes an array or
  // a struct -- MshrNum, MshrWaysPerBank, MshrMergeReqs, RespBufWords, DrainBeats -- stays an
  // elaboration parameter and is absent by construction.
  //
  // The whole struct const-folds to the elaborated constants when MshrCfgRuntime = 0, so a
  // fixed-function build is bit-identical to the pre-CSR design and keeps the hold-block const-fold.
  // MshrCfgRuntime: 0 = every CSR const-folds to its default and the file has no storage, so the
  // build is bit-identical to the pre-CSR design AND the hold block still folds away on shapes that
  // pin the window to 0. 1 = software-writable. Development/characterisation want 1.
  localparam bit MshrCfgRuntime =
    `ifdef GROUP_MSHR_CFG_RUNTIME `GROUP_MSHR_CFG_RUNTIME `else 1'b0 `endif;

  // Reset values for the CSR file. These MIRROR mempool_group_mshr.sv's own localparam chains and
  // must stay identical to them -- the reset state is what makes an unconfigured run reproduce the
  // pre-CSR design exactly (verification gate V1). Each `ifdef chain below is copied verbatim from
  // the MSHR; if one changes there, change it here.
  localparam integer unsigned MshrDefMergeReqs =
    `ifdef GROUP_MSHR_MERGE_REQS `GROUP_MSHR_MERGE_REQS `else 8 `endif;
  localparam integer unsigned MshrDefHoldWindow =
    `ifdef GROUP_MSHR_HOLD_WINDOW `GROUP_MSHR_HOLD_WINDOW `else 0 `endif;
  localparam integer unsigned MshrDefHoldWindowSingle =
    `ifdef GROUP_MSHR_HOLD_WINDOW_SINGLE `GROUP_MSHR_HOLD_WINDOW_SINGLE `else MshrDefHoldWindow `endif;
  localparam integer unsigned MshrDefHoldWindowBurst =
    `ifdef GROUP_MSHR_HOLD_WINDOW_BURST `GROUP_MSHR_HOLD_WINDOW_BURST `else MshrDefHoldWindow `endif;
  localparam integer unsigned MshrDefHoldSubs =
    `ifdef GROUP_MSHR_HOLD_SUBS `GROUP_MSHR_HOLD_SUBS `else 2 `endif;
  localparam integer unsigned MshrDefHoldSubsSingle =
    `ifdef GROUP_MSHR_HOLD_SUBS_SINGLE `GROUP_MSHR_HOLD_SUBS_SINGLE `else MshrDefHoldSubs `endif;
  localparam integer unsigned MshrDefHoldSubsBurst =
    `ifdef GROUP_MSHR_HOLD_SUBS_BURST `GROUP_MSHR_HOLD_SUBS_BURST `else MshrDefHoldSubs `endif;
  localparam integer unsigned MshrDefServeTimeout =
    `ifdef GROUP_MSHR_SERVE_TIMEOUT `GROUP_MSHR_SERVE_TIMEOUT `else 0 `endif;
  // Both 0 = legacy (see mshr_cfg_t). Reset values only when MshrCfgRuntime=1.
  localparam integer unsigned MshrDefCacheReuseTarget =
    `ifdef GROUP_MSHR_CACHE_REUSE_TARGET `GROUP_MSHR_CACHE_REUSE_TARGET `else 0 `endif;
  localparam integer unsigned MshrDefCacheTimeout =
    `ifdef GROUP_MSHR_CACHE_TIMEOUT `GROUP_MSHR_CACHE_TIMEOUT `else 0 `endif;
  localparam integer unsigned MshrDefBankfullBp =
    `ifdef GROUP_MSHR_BANKFULL_BACKPRESSURE `GROUP_MSHR_BANKFULL_BACKPRESSURE `else 0 `endif;
  localparam integer unsigned MshrDefBankSelShift =
    `ifdef GROUP_MSHR_BANK_SHIFT `GROUP_MSHR_BANK_SHIFT `else 5 `endif;
  localparam integer unsigned MshrDefBankShiftSingle =
    `ifdef GROUP_MSHR_BANK_SHIFT_SINGLE `GROUP_MSHR_BANK_SHIFT_SINGLE `else MshrDefBankSelShift `endif;
  localparam integer unsigned MshrDefBankShiftBurst =
    `ifdef GROUP_MSHR_BANK_SHIFT_BURST `GROUP_MSHR_BANK_SHIFT_BURST `else MshrDefBankSelShift `endif;
  localparam integer unsigned MshrDefBankBurstBits =
    `ifdef GROUP_MSHR_BANK_BURST_BITS `GROUP_MSHR_BANK_BURST_BITS `else 1 `endif;
  // Mirrors the MSHR guard at mempool_group_mshr.sv:328: serve_timeout == 0 pins a CACHED way
  // forever when the serve target is never reached and the entry is not an eviction victim.
  localparam bit MshrRespWaitSubsSingle =
    `ifdef GROUP_MSHR_RESP_WAIT_SUBS_SINGLE `GROUP_MSHR_RESP_WAIT_SUBS_SINGLE `else 1'b0 `endif;
  localparam bit MshrCacheReclaimable =
    `ifdef GROUP_MSHR_CACHE_RECLAIMABLE `GROUP_MSHR_CACHE_RECLAIMABLE `else 1'b0 `endif;
  localparam bit MshrServeTimeoutNonZero = MshrRespWaitSubsSingle || !MshrCacheReclaimable;

  // 4095, not 2047: the RH-livelock experiment needs a serve_timeout/hold window ABOVE the old
  // bound, and the CSR write path REFUSES anything over MshrCfgHoldCntMax (mempool_group_mshr_cfg.sv
  // cnt_ok, :129) -- so a 4095 write against an 11-bit build silently kept the reset default and set
  // the sticky RANGE bit, producing an arm that looks configured and is not. Widen both together:
  // mshr_cfg.sv:122 $errors if the width cannot represent the max, so a half-change fails loudly.
  // Note HoldCntMax is pinned to THIS constant whenever MshrCfgRuntime=1 (mempool_group_mshr.sv:273),
  // so build knobs alone cannot widen the counter -- only these two literals do.
  // 8191/13. The window must cover the arrival skew of a cohort that CAN actually form -- the
  // can-burst shapes (e.g. fp16_4096x32x512: burst target 8, B slice 512 B) where 8 cores really
  // do share the B line but need longer than 2047 cycles to converge. Shapes whose B slice is
  // below the 64 B burst floor are NOT the target: they cannot merge at any window length
  // (rh_livelock_root_cause.md section 0), and should be kept out of future sweeps instead.
  //
  // This bound is ONLY effective if it is wired to mempool_group_mshr_cfg's HoldCntHwMax
  // parameter -- see mempool_group.sv. It was not, and that module's own default of 2047 silently
  // refused every write above it: the 4095 campaign wrote 4095, had it dropped, and ran at the
  // 2047 reset value while reporting no error (MSHR_STATUS_RANGE is never $displayed; the
  // observable is software's "[MSHR] cfg REJECTED ... MEASUREMENT INVALID").
  localparam integer unsigned MshrCfgHoldCntMax = 8191; // hardware bound on window / serve_timeout
  localparam integer unsigned MshrCfgHoldCntW   = 13;  // bound 8191
  // MUST hold MshrMergeReqs, whose largest shipped value is 16 -- so 5 bits, not 4.
  //
  // At 4 bits this silently truncated: subs_ok range-checks the FULL 32-bit write (so 16 <= 16
  // passes), and the very next line casts to MshrCfgSubsW, turning 16 into 0. Every 128x*x512
  // shape pins hold_subs_single = 16, so all four wrote 0, the merge-admission compare
  // (sub_reqs_num < cfg_hold_subs_single) was never true, and singles stopped merging: measured
  // merged_single 230,224 -> 179,222 with alloc_single 15,356 -> 48,816 on 128x128x512. It read as
  // a 43% "improvement" because that shape happens to run faster with merging crippled.
  //
  // Third instance of one bug class -- after HoldCntW and ServedCntMax -- and the only one that
  // fires in a shipped configuration. The others were latent.
  // 6, not 5: hold_subs_* need only span [1, MshrMergeReqs] (16), but cache_reuse_target shares
  // this width and its legal range is [0, 2*MshrMergeReqs] (32) -- two successive cohorts of the
  // SAME line, which is the whole point of the reuse target. 5 bits caps at 31, so the shipped
  // 128x*x512 value of 32 could not be represented at all.
  localparam integer unsigned MshrCfgSubsW      = 6;   // hold_subs [1, MergeReqs]; reuse target [0, 2*MergeReqs]
  localparam integer unsigned MshrCfgShiftW     = 4;   // raw shift; the RTL muxes over a small range
  // bank_burst_bits: how many of the BankIdW bank bits come from WITHIN the load (which burst
  // of this load) rather than from the gap between p-slices. Was a single bit, which silently
  // truncated the software-derived 2/3/4 to its LSB and left KS=4/1 with 4 of 16 banks
  // reachable.
  //
  // DERIVED from the MSHR bank count, not hardcoded: the legal range is [0, BankIdW], so the
  // field needs clog2(BankIdW+1) bits. These three mirror mempool_group_mshr.sv:487-488
  // exactly -- MshrTagNum is driven by the same GROUP_MSHR_NUM macro as its MshrNum, and the
  // ways knob by the same GROUP_MSHR_WAYS_PER_BANK -- so re-sizing the MSHR re-sizes the CSR
  // with it and the two can never drift apart.
  localparam integer unsigned MshrCfgWaysPerBank =
      `ifdef GROUP_MSHR_WAYS_PER_BANK `GROUP_MSHR_WAYS_PER_BANK `else 1 `endif;
  localparam integer unsigned MshrCfgBankNum =
      (MshrCfgWaysPerBank > 0) ? (MshrTagNum / MshrCfgWaysPerBank) : 1;
  localparam integer unsigned MshrCfgBankIdW = idx_width(MshrCfgBankNum);
  // MshrCfgBankIdW is the largest bank_burst_bits the HASH COULD use; it is derived here so a
  // re-sized MSHR moves it automatically. The implemented field is ONE BIT, because bb<=1
  // reaches the achievable ceiling on every shape this design runs (all 88 merging burst
  // classes in the decode grid need only bb=0; KS=8 prefill needs at most bb=1). A wider field
  // would buy a single one-off KS=4 prefill shape at the cost of a second variable shift in
  // the bank-select path.
  // A write ABOVE this width is REFUSED with MSHR_STATUS_RANGE by mempool_group_mshr_cfg --
  // never truncated. That is the whole point: the gap is loud, not silent.
  localparam integer unsigned MshrCfgBurstBitsCeil = MshrCfgBankIdW;
  localparam integer unsigned MshrCfgBurstBitsW    = 1;

  typedef struct packed {
    logic                            enable;              // 0 = every request bypasses the MSHR
    logic [MshrCfgSubsW-1:0]         hold_subs_single;    // 1 => singles bypass (no merging wanted)
    logic [MshrCfgSubsW-1:0]         hold_subs_burst;     // 1 => bursts bypass
    logic [MshrCfgHoldCntW-1:0]      hold_window_single;  // request-side hold, single entries
    logic [MshrCfgHoldCntW-1:0]      hold_window_burst;   // request-side hold, burst entries
    logic [MshrCfgHoldCntW-1:0]      serve_timeout;       // response-side, SINGLE-ONLY (RESP_HOLD/CACHED)
    logic [MshrCfgShiftW-1:0]        bank_shift_single;   // bank-hash address bit select, singles
    logic [MshrCfgShiftW-1:0]        bank_shift_burst;    // ... bursts
    logic [MshrCfgBurstBitsW-1:0]    bank_burst_bits;     // 0 or 1; a larger write is REFUSED, not truncated
    // Cache reuse target (fp16 half-word aliasing). 0 = LEGACY: a CACHED line self-invalidates at
    // hold_subs_{single,burst}, exactly as before this field existed. Non-zero = the line instead
    // survives until served_cnt reaches THIS value, so a second cohort addressing the other half
    // of the same 32-bit word is served from the line rather than splitting off a fresh entry that
    // waits out serve_timeout for peers already served. Range [1, MshrMergeReqs] -- served_cnt
    // saturates at ServedCntMax = MshrMergeReqs, so a larger target is unreachable by construction.
    logic [MshrCfgSubsW-1:0]         cache_reuse_target;
    // CACHED-phase residency countdown. 0 = LEGACY: the cache phase re-arms from serve_timeout.
    // Non-zero = arm from this instead, so cache residency is tunable independently of how long a
    // RESP_HOLD entry waits for subscribers.
    logic [MshrCfgHoldCntW-1:0]      cache_timeout;
    // Bank-full policy for a MERGEABLE miss. 0 = LEGACY: bypass the MSHR and go straight to the
    // NoC. 1 = BACKPRESSURE: stall the request until a way frees, exactly as the design already
    // does when the bank has a free way but the request lost that bank's single alloc slot.
    //
    // Why: a bypass SPLITS a cohort. Part of a round bypasses (bank full at that instant), the
    // bank then frees, and a later member of the same round allocates a FRESH entry whose
    // subscriber target counts peers that have already been served via the bypass path and will
    // never subscribe -- so it waits out serve_timeout. Measured on the idea-2 sweep: arms with a
    // non-zero cache_reuse_target keep lines resident longer, sit bank-full far more often, and
    // show ~500x the bank-full bypass count of the arms where the target is inactive
    // (median 1,579 vs 3), which is where the 7-28x collapses live.
    //
    // Stalling instead lets the late peer MERGE into the resident entry once it is reachable,
    // which is the outcome the bypass destroys. Bounded by serve_timeout: a held entry always
    // releases eventually, so a full bank cannot wedge a port permanently.
    logic                            bankfull_backpressure;
  } mshr_cfg_t;

  // CSR indices, mirrored by software/runtime/mshr_cfg.h -- keep the two in step.
  localparam integer unsigned MSHR_CSR_ENABLE             = 0;
  localparam integer unsigned MSHR_CSR_HOLD_SUBS_SINGLE   = 1;
  localparam integer unsigned MSHR_CSR_HOLD_SUBS_BURST    = 2;
  localparam integer unsigned MSHR_CSR_HOLD_WINDOW_SINGLE = 3;
  localparam integer unsigned MSHR_CSR_HOLD_WINDOW_BURST  = 4;
  localparam integer unsigned MSHR_CSR_BANK_SHIFT_SINGLE  = 5;
  localparam integer unsigned MSHR_CSR_BANK_SHIFT_BURST   = 6;
  localparam integer unsigned MSHR_CSR_BANK_BURST_BITS    = 7;
  localparam integer unsigned MSHR_CSR_SERVE_TIMEOUT      = 8;
  localparam integer unsigned MSHR_CSR_CACHE_REUSE_TARGET = 9;
  localparam integer unsigned MSHR_CSR_CACHE_TIMEOUT      = 10;
  localparam integer unsigned MSHR_CSR_BANKFULL_BP       = 11;
  localparam integer unsigned MSHR_CSR_STATUS             = 15;

  // CFG_STATUS sticky error bits. Software reads this after configuring; a set bit means the
  // configuration in effect is NOT the one requested -- the exact class of silent mismatch that
  // cost three invalid measurement runs on 2026-08-14.
  localparam integer unsigned MSHR_STATUS_BANK_BUSY   = 0;  // bank-hash write refused: MSHR not empty
  localparam integer unsigned MSHR_STATUS_RANGE       = 1;  // a value was out of range and clamped
  localparam integer unsigned MSHR_STATUS_TIMEOUT_ZERO= 2;  // serve_timeout=0 refused (would pin a way)
  localparam integer unsigned MSHR_STATUS_BAD_INDEX   = 3;  // write to an undefined CSR index

endpackage : mempool_pkg
