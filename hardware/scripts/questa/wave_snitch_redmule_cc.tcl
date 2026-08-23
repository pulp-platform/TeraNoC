# Copyright 2026 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

set cc_path /mempool_tb/dut/i_mempool_cluster/gen_groups_x\[[expr ${1}/${3}]\]/gen_groups_y\[[expr ${1}%${3}]\]/gen_rtl_group/i_group/i_mempool_group/gen_tiles\[$2\]/i_tile/gen_cores\[0\]/gen_snitch_redmule_cc/i_snitch_redmule_cc

set core_group core_${1}_${2}_0
add wave -noupdate -group $core_group -group CC ${cc_path}/*
add wave -noupdate -group $core_group -group Snitch ${cc_path}/riscv_core/*
add wave -noupdate -group $core_group -group Snitch -group Integer ${cc_path}/riscv_core/i_snitch/*
add wave -noupdate -group $core_group -group RedMulE ${cc_path}/i_redmule_top/*
add wave -noupdate -group $core_group -group RedMulE -group Control ${cc_path}/i_redmule_top/i_control/*
add wave -noupdate -group $core_group -group RedMulE -group Scheduler ${cc_path}/i_redmule_top/i_scheduler/*
