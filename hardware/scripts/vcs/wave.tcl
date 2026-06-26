# Copyright 2021 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

set _nWave2 [wvCreateWindow]

# --- Helper procs (inlined questa wave_core / wave_tile / wave_cache /
#     wave_cluster). $g/$t/$c are group/tile/core ids, $NumY the mesh height,
#     exactly mirroring the helpers' $1/$2/$3/$4 positional args. ---
proc wave_core {g t c NumY} {
    global _nWave2
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/BootAddr"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/MTVEC"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/RVE"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/RVM"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/RegisterOffloadReq"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/RegisterOffloadResp"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/RegisterTCDMReq"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/RegisterTCDMResp"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/clk_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/rst_ni"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/hart_id_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/inst_addr_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/inst_data_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/inst_valid_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/inst_ready_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qaddr_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qwrite_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qamo_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qdata_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qstrb_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qvalid_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_qready_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_pdata_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_perror_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_pvalid_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/data_pready_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qaddr_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qid_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qdata_op_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qdata_arga_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qdata_argb_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qdata_argc_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qvalid_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_qready_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_pdata_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_pid_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_perror_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_pvalid_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_pready_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/acc_req_valid_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/acc_req_ready_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/acc_resp_valid_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/acc_resp_ready_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/operands_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/rnd_mode_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/op_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/op_mod_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/src_fmt_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/dst_fmt_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/int_fmt_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/vectorial_op_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/tag_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/in_valid_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/in_ready_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/result_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/status_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/tag_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/out_valid_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/gen_fpu/i_snitch_fp_ss/i_fpu/out_ready_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/illegal_inst"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/stall"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/lsu_stall"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_stall"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/zero_lsb"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/pc_d"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/pc_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/wfi_d"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/wfi_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/wake_up_sync_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/wake_up_d"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/wake_up_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/ls_size"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/ls_amo"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/ld_result"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/lsu_qready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/lsu_qvalid"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/lsu_pvalid"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/lsu_pready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/lsu_rd"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/retire_load"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/retire_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/retire_acc"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/i_snitch_regfile/raddr_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/i_snitch_regfile/waddr_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/i_snitch_regfile/wdata_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/i_snitch_regfile/we_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/i_snitch_regfile/rdata_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/i_snitch_regfile/mem"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/opa"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/opb"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/iimm"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/uimm"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/jimm"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/bimm"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/simm"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/adder_result"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/alu_result"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/rd"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/rs1"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/rs2"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/gpr_raddr"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/gpr_rdata"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/gpr_waddr"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/gpr_wdata"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/gpr_we"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/consec_pc"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/sb_d"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/sb_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/is_load"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/is_store"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/is_signed"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/is_fp_load"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/is_fp_store"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/ls_misaligned"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/ld_addr_misaligned"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/st_addr_misaligned"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/valid_instr"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/exception"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/alu_op"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/opa_select"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/opb_select"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/write_rd"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/uses_rd"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/next_pc"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/rd_select"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/rd_bypass"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/is_branch"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/csr_rvalue"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/csr_en"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/cycle_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/instret_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/acc_register_rd"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/operands_ready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/dst_ready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/opa_ready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/opb_ready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_opa"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_opa_reversed"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_right_result"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_left_result"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_opa_ext"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_right_result_ext"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_left"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/shift_arithmetic"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/alu_opa"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/alu_opb"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/alu_writeback"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/csr_trace_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/csr_trace_en"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_cores\[${c}\]/gen_mempool_cc/riscv_core/i_snitch/core_events_o"
}

proc wave_tile {g t NumY} {
    global _nWave2
    wvAddSignal -win $_nWave2 {/mempool_pkg::NumBanksPerTile}
    wvAddSignal -win $_nWave2 {/mempool_pkg::NumTiles}
    wvAddSignal -win $_nWave2 {/mempool_pkg::NumBanks}
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/TCDMBaseAddr"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/BootAddr"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[0\].i_snitch_icache.LINE_WIDTH"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[0\].i_snitch_icache.LINE_COUNT"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[0\].i_snitch_icache.WAY_COUNT"
    wvAddSignal -win $_nWave2 {/mempool_pkg::ICacheLineWidth}
    wvAddSignal -win $_nWave2 {/mempool_pkg::ICacheSizeByte}
    wvAddSignal -win $_nWave2 {/mempool_pkg::ICacheWays}
    wvAddSignal -win $_nWave2 {/mempool_pkg::NumCores}
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/clk_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/rst_ni"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/scan_enable_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/scan_data_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/scan_data_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/tile_id_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/tcdm_master_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/tcdm_slave_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/axi_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/snitch_inst_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/snitch_data_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/bank_req_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/bank_resp_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/postreg_tcdm_slave_req_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/prereg_tcdm_slave_resp_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/prereg_tcdm_master_req_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/postreg_tcdm_master_resp_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/remote_req_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/remote_resp_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/local_req_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/local_resp_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_data_*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/mask_map"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_req_o"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_resp_i"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_qvalid"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_qready"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_pvalid"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/soc_pready"
    for {set i 0} {$i < 16} {incr i} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_banks\[${i}\]/i_tcdm_adapter/*"
    }
}

proc wave_cache {g t c NumY} {
    global _nWave2
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/NR_FETCH_PORTS"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/L0_LINE_COUNT"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/LINE_WIDTH"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/LINE_COUNT"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/WAY_COUNT"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/FETCH_DW"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/FILL_AW"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/FILL_DW"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/EARLY_LATCH"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/L0_EARLY_TAG_WIDTH"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/ISO_CROSSING"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/*"
    for {set i 0} {$i < [get -radix dec /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/NR_FETCH_PORTS]} {incr i} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/gen_prefetcher\[${i}\]/i_snitch_icache_l0/*"
    }
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/gen_serial_lookup/i_lookup/*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/i_handler/*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/i_handler/pending_q"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr  ${g}/${NumY}]\]/gen_groups_y\[[expr  ${g}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${t}\]/i_tile/gen_caches\[${c}\]/i_snitch_icache/i_refill/*"
}

proc wave_cluster {} {
    global _nWave2
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/TCDMBaseAddr}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/BootAddr}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/NumDMAReq}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/NumAXIMasters}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/clk_i}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/rst_ni}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/ro_cache_ctrl_i}
    wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_cluster/dma_*}
}

# --- Config bounds (read live from the elaborated design) ---
set NumX [get -radix dec mempool_pkg::NumX]
set NumY [get -radix dec mempool_pkg::NumY]

# --- Utilization vector (overview of system activity) ---
wvAddSignal -win $_nWave2 {/mempool_tb/snitch_utilization}
wvAddSignal -win $_nWave2 {/mempool_tb/instruction_handshake}
wvAddSignal -win $_nWave2 {/mempool_tb/lsu_utilization}
wvAddSignal -win $_nWave2 {/mempool_tb/lsu_handshake}
wvAddSignal -win $_nWave2 {/mempool_tb/lsu_pressure}
wvAddSignal -win $_nWave2 {/mempool_tb/lsu_request}
if {[get -radix dec /snitch_pkg::XPULPIMG]} {
    wvAddSignal -win $_nWave2 {/mempool_tb/gen_utilization/dspu_utilization}
    wvAddSignal -win $_nWave2 {/mempool_tb/gen_utilization/dspu_handshake}
    wvAddSignal -win $_nWave2 {/mempool_tb/gen_utilization/mac_utilization}
    wvAddSignal -win $_nWave2 {/mempool_tb/gen_utilization/dspu_mac}
}
wvAddSignal -win $_nWave2 {/mempool_tb/axi_w_utilization}
wvAddSignal -win $_nWave2 {/mempool_tb/axi_r_utilization}

# --- wfi vector (which cores are active) ---
wvAddSignal -win $_nWave2 {/mempool_tb/wfi}

# --- Per-tile SPM superbank request valids ---
for {set group 0} {$group < [get -radix dec mempool_pkg::NumGroups]} {incr group} {
    for {set tile 0} {$tile < [get -radix dec mempool_pkg::NumTilesPerGroup]} {incr tile} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${group}/${NumX}]\]/gen_groups_y\[[expr ${group}%${NumY}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[${tile}\]/i_tile/superbank_req_valid"
    }
}

# --- All cores from group 0 tile 0 ---
for {set core 0} {$core < [get -radix dec mempool_pkg::NumCoresPerTile]} {incr core} {
    wave_core 0 0 $core $NumY
}

# --- Specific cores from different tiles ---
wave_core 1 0 0 $NumY
wave_core 1 1 1 $NumY
wave_core [expr [get -radix dec mempool_pkg::NumGroups]-1] [expr [get -radix dec mempool_pkg::NumTilesPerGroup]-1] [expr [get -radix dec mempool_pkg::NumCoresPerTile]-1] $NumY

# --- Groups ---
set DmaBurstLen [get -radix dec mempool_pkg::DmaBurstLen]
set Interleave [get -radix dec mempool_pkg::Interleave]

for {set group 0} {$group < [get -radix dec mempool_pkg::NumGroups]} {incr group} {
    set gx [expr ${group}/${NumX}]
    set gy [expr ${group}%${NumY}]
    # Interface
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/*"
    # Addr Map
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/addr_map"
    # Tiles
    for {set tile 0} {$tile < [get -radix dec mempool_pkg::NumTilesPerGroup]} {incr tile} {
        wave_tile $group $tile $NumY
    }
    # Local TCDM
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/tcdm_master_req*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/tcdm_master_resp*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/tcdm_slave_req*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/tcdm_slave_resp*"
    # TCDM Router - Request Ports (wide + narrow)
    for {set tile 0} {$tile < [get -radix dec mempool_pkg::NumTilesPerGroup]} {incr tile} {
        # Wide Request Ports
        for {set port 1} {$port < [get -radix dec mempool_pkg::NumWideRemoteReqPortsPerTile]} {incr port} {
            wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/gen_router_router_i\[${tile}\]/gen_router_wide_req_router_j\[${port}\]/gen_2dmesh/i_floo_tcdm_wide_req_router/*"
        }
        # Narrow Request Ports (optional, only if enabled)
        for {set port 1} {$port < [get -radix dec mempool_pkg::NumNarrowRemoteReqPortsPerTile]} {incr port} {
            wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/gen_router_router_i\[${tile}\]/gen_router_narrow_req_router_j\[${port}\]/gen_2dmesh/i_floo_tcdm_narrow_req_router/*"
        }
    }
    # TCDM Router - Response Ports (only wide)
    for {set tile 0} {$tile < [get -radix dec mempool_pkg::NumTilesPerGroup]} {incr tile} {
        for {set port 1} {$port < [get -radix dec mempool_pkg::NumRemoteRespPortsPerTile]} {incr port} {
            wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/gen_router_router_i\[${tile}\]/gen_router_wide_resp_router_j\[${port}\]/gen_2dmesh/i_floo_tcdm_wide_resp_router/*"
        }
    }
    # Splitter & Interleaver
    if {$DmaBurstLen > $Interleave} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/gen_axi_splitter/i_axi_burst_splitter/*"
    }
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_axi_L2_interleaver/*"
    # AXI Router
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_floo_narrow_wide_chimney/*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_floo_narrow_wide_router/*"
}

# --- Cluster ---
wave_cluster

# --- System ---
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_soc_xbar/*}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_axi2mem_bootrom/*}
if {[get -radix dec mempool_pkg::NumDrams] ne ""} {
    for {set dram 0} {$dram < [get -radix dec mempool_pkg::NumDrams]} {incr dram} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/gen_drams\[${dram}\]/i_axi_dram_sim/*"
    }
} else {
    for {set bank 0} {$bank < [get -radix dec mempool_pkg::NumL2Banks]} {incr bank} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/gen_l2_adapters\[${bank}\]/i_axi2mem/*"
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/gen_l2_banks\[${bank}\]/l2_mem/*"
    }
}

# --- AXI (cluster master) ---
wvAddSignal -win $_nWave2 {/mempool_tb/dut/axi_mst_req}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/axi_mst_resp}

# --- CSR ---
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_ctrl_registers/*}

# --- DMA ---
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_dma/*}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_mempool_dma/i_mempool_dma_frontend_reg_top/*}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/NoMstPorts}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/DmaRegionWidth}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/DmaRegionStart}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/DmaRegionEnd}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/DmaRegionAddressBits}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/FullRegionAddressBits}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_distributed_midend/*}
wvAddSignal -win $_nWave2 {/mempool_tb/dut/i_idma_split_midend/*}

for {set group 0} {$group < [get -radix dec mempool_pkg::NumGroups]} {incr group} {
    set gx [expr ${group}/${NumX}]
    set gy [expr ${group}%${NumY}]
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/NoMstPorts"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionWidth"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionStart"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionEnd"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/DmaRegionAddressBits"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/FullRegionAddressBits"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/i_idma_distributed_midend/*"
    for {set dma 0} {$dma < [get -radix dec mempool_pkg::NumDmasPerGroup]} {incr dma} {
        wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/gen_dmas\[${dma}\]/i_axi_dma_backend/*"
    }
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/tcdm_dma_req*"
    wvAddSignal -win $_nWave2 "/mempool_tb/dut/i_mempool_cluster/gen_groups_x\[${gx}\]/gen_groups_y\[${gy}\]/gen_rtl_group/i_group/i_mempool_group/tcdm_dma_resp*"
}

# --- RO instruction cache (group 0 / tile 0 / core 0) ---
wave_cache 0 0 0 $NumY

wvZoomAll -win $_nWave2
