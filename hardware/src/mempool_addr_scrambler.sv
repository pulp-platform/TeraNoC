// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// SPM address scrambler. Single combinational module applying up to two
// independently-gated address transforms:
//   Stage 1 (EnableSeqInterleaveSwap, sequential region): swap the
//     {tile_id, scramble} fields so HW sees an interleaved-bank layout.
//   Stage 2 (EnableTileIdRemap, non-sequential TCDM): spread accesses
//     across the NumTilesPerDma tiles of a DMA group.
//
// Used by snitch cores pre-tcdm_shim (both stages on) and by the DMA
// tile-id path in mempool_group.sv (Stage 1 off, Stage 2 on; caller then
// slices tile_id_remap out of address_o for the reqrsp_demux select).
// Replaces address_scrambler.sv and mempool_dma_tile_id_remapper.sv.
//
// NOTE: bank-id remap is intentionally NOT here — it lives in the tile's
// bank-side network (mempool_bank_id_remapper).

module mempool_addr_scrambler
#(
  parameter int unsigned          AddrWidth                = 32,
  parameter int unsigned          ByteOffset               = 2,
  parameter int unsigned          NumTiles                 = 2,
  parameter int unsigned          NumTilesPerDma           = 16,
  parameter int unsigned          NumBanksPerTile          = 2,
  parameter bit                   Bypass                   = 1'b0,
  parameter int unsigned          SeqMemSizePerTile        = 4*1024,
  parameter logic [AddrWidth-1:0] TCDMBaseAddr             = 32'b0,
  parameter logic [31:0]          TCDMMask                 = '1 << 28,
  parameter bit                   EnableSeqInterleaveSwap  = 1'b1,
  parameter bit                   EnableTileIdRemap        = 1'b0
) (
  input  logic [AddrWidth-1:0] address_i,
  output logic [AddrWidth-1:0] address_o
);

  `define max(a,b) (((a) > (b))? (a) : (b))

  localparam int unsigned BankOffsetBits    = $clog2(NumBanksPerTile);
  localparam int unsigned TileIdBits        = $clog2(NumTiles);
  localparam int unsigned TileIdBitsPerDma  = `max(1, $clog2(NumTilesPerDma));
  localparam int unsigned SeqPerTileBits    = $clog2(SeqMemSizePerTile);
  localparam int unsigned SeqTotalBits      = SeqPerTileBits + TileIdBits;
  localparam int unsigned ConstantBitsLSB   = ByteOffset + BankOffsetBits;
  localparam int unsigned ScrambleBits      = SeqPerTileBits - ConstantBitsLSB;

  logic not_io_address;
  assign not_io_address = (address_i & TCDMMask) == TCDMBaseAddr;

  function automatic logic [TileIdBitsPerDma-1:0] spm_tile_id_remap (
      logic [TileIdBitsPerDma-1:0] data_in,
      logic [TileIdBitsPerDma-1:0] idx_i
  );
    if (EnableTileIdRemap) begin
      spm_tile_id_remap = data_in + idx_i;
    end else begin
      spm_tile_id_remap = data_in;
    end
  endfunction

  if (Bypass || NumTiles < 2) begin : gen_bypass
    assign address_o = address_i;
  end else begin : gen_active
    logic [ScrambleBits-1:0] scramble;
    logic [TileIdBits-1:0]   tile_id;

    assign scramble = address_i[SeqPerTileBits-1:ConstantBitsLSB];
    assign tile_id  = address_i[SeqTotalBits-1:SeqPerTileBits];

    always_comb begin
      address_o = address_i;

      // Stage 1: sequential→interleaved field swap (sequential region only).
      if (EnableSeqInterleaveSwap && (address_i < (NumTiles * SeqMemSizePerTile))) begin
        address_o[SeqTotalBits-1:ConstantBitsLSB] = {scramble, tile_id};
      end
      // Stage 2: tile-id remap, interleaved region only — never rewrite the
      // sequential region's offset bits (matches the old dma_tile_id_remapper).
      else if (EnableTileIdRemap && not_io_address &&
               (address_i >= (NumTiles * SeqMemSizePerTile))) begin
        address_o[ConstantBitsLSB +: TileIdBitsPerDma] =
          spm_tile_id_remap(
            address_i[ConstantBitsLSB +: TileIdBitsPerDma],
            address_i[(ConstantBitsLSB + TileIdBits) +: TileIdBitsPerDma]
          );
      end
    end
  end : gen_active

  // Check for unsupported configurations
  if (NumBanksPerTile < 2)
    $fatal(1, "NumBanksPerTile must be greater than 2. The special case '1' is currently not supported!");
  if (SeqMemSizePerTile % (2**ByteOffset*NumBanksPerTile) != 0)
    $fatal(1, "SeqMemSizePerTile must be a multiple of BankWidth*NumBanksPerTile!");

endmodule : mempool_addr_scrambler
