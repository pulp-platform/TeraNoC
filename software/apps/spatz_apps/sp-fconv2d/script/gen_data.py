#!/usr/bin/env python3
# Copyright 2022 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>

import numpy as np
import torch
import torch.nn as nn
import argparse
import pathlib
import numpy as np
import scipy
import hjson
from functools import reduce
from scipy import signal

np.random.seed(42)
torch.manual_seed(42)

global verbose

# 在文件开头添加这个辅助函数
def float_to_hex(val):
    # 将 float 转换为十六进制，以 uint32 视角（匹配 C 的打印方式）
    import struct
    bytes_data = struct.pack('<f', val)  # 小端序打包
    uint_val = struct.unpack('<I', bytes_data)[0]  # 小端序解包为 uint32
    return f"0x{uint_val:08x}"


def array_to_cstr(a, fmt=float):
    out = '{'
    if fmt == float:
        if isinstance(a, np.ndarray):
            a = a.flat
        if isinstance(a, torch.Tensor):
            a = a.numpy().flat
        for el in a:
            out += f"{float(el):.8f}f, "
            
    else:
        for sign, exp, mant in zip(a['sign'].numpy().flat, a['exponent'].numpy().flat, a['mantissa'].numpy().flat):
            value = sign * 2**7 + exp * 2**2 + mant
            out += "0x{:02x}, ".format(value)
    out = out[:-2] + '}'
    return out


def emit_header_file(layer_type: str, **kwargs):

    cores = kwargs['cores']
    file_path = pathlib.Path(__file__).parent.parent / 'data'
    emit_str = "// Copyright 2022 ETH Zurich and University of Bologna.\n" + \
               "// Licensed under the Apache License, Version 2.0, see LICENSE for details.\n" + \
               "// SPDX-License-Identifier: Apache-2.0\n\n"

    file = file_path / 'data_fconv2d.h'
    emit_str += emit_fconv2d_layer(**kwargs)
    with file.open('w') as f:
        f.write(emit_str)

def emit_fconv2d_layer(name='fconv2d', **kwargs):
    vec_I  = kwargs['imtx']
    vec_F  = kwargs['fmtx']
    vec_R  = kwargs['rmtx']
    vec_GR = kwargs['grmtx']

    ch = kwargs['CH']
    r  = kwargs['R']
    c  = kwargs['C']
    f  = kwargs['F']
    r_dim_core = kwargs['r_dim_core']
    c_dim_core = kwargs['c_dim_core']
    cores = kwargs['cores']

    layer_str = ''
    layer_str += '#include "layer.h"\n\n'
    layer_str += f'fconv2d_layer {name}_l = {{\n'
    layer_str += f'\t.CH = {ch},\n'
    layer_str += f'\t.R  = {r},\n'
    layer_str += f'\t.C  = {c},\n'
    layer_str += f'\t.F  = {f},\n'
    layer_str += f'\t.r_dim_core = {r_dim_core},\n'
    layer_str += f'\t.c_dim_core = {c_dim_core},\n'
    layer_str += f'\t.dtype = FP{kwargs["prec"]},\n'
    layer_str += '};\n\n\n'

    ctypes = {
        '64': 'double',
        '32': 'float',
        '16': '__fp16',
        '8': 'char'
    }

    dtype = ctypes[str(kwargs['prec'])]

    if dtype != 'char':
        layer_str += f'const uint32_t active_cores = {cores};\n'
        layer_str += f'{dtype} imtx[{ch}*{r+f-1}*{c+f-1}] __attribute__((section(".l1_prio")))' + ';\n'
        layer_str += f'{dtype} omtx[{r}*{c}] __attribute__((section(".l1_prio")))' + ';\n'
        layer_str += f'{dtype} fmtx[{ch}*{f}*{f}] __attribute__((section(".l1_prio")))' + ';\n'

        layer_str += f'static {dtype} {name}_I_dram [{ch}*{r+f-1}*{c+f-1}] __attribute__((section(".data"))) = ' + array_to_cstr(vec_I) + ';\n\n\n'
        layer_str += f'static {dtype} {name}_F_dram [{ch}*{f}*{f}] __attribute__((section(".data"))) = ' + array_to_cstr(vec_F) + ';\n\n\n'
        layer_str += f'static {dtype} {name}_R_dram [{r}*{c}] __attribute__((section(".data"))) = ' + array_to_cstr(vec_R) + ';\n\n\n'
        layer_str += f'static {dtype} {name}_GR_dram [{r}*{c}] __attribute__((section(".data"))) = ' + array_to_cstr(vec_GR) + ';\n\n\n'
    else:
        layer_str += f'static {dtype} {name}_I_dram [{ch}*{r+f-1}*{c+f-1}] = ' + \
            array_to_cstr(kwargs['bits_I'], fmt='char') + ';\n\n\n'
        layer_str += f'static {dtype} {name}_F_dram [{ch}*{f}*{f}] = ' + \
            array_to_cstr(kwargs['bits_F'], fmt='char') + ';\n\n\n'
        layer_str += f'static {dtype} {name}_R_dram [{r}*{c}] = ' + \
            array_to_cstr(kwargs['bits_R'], fmt='char') + ';\n\n\n'
        layer_str += f'static {dtype} {name}_GR_dram [{r}*{c}] = ' + \
            array_to_cstr(kwargs['bits_R'], fmt='char') + ';\n\n\n'

    return layer_str


def rand_data_generator(shape, prec, alt=False):
    if prec == 64:
        return torch.randn(shape, requires_grad=False, dtype=torch.float64), {}
    elif prec == 32:
        return torch.randn(shape, requires_grad=False, dtype=torch.float32), {}
    elif prec == 16:
        if alt:
            return torch.randn(shape, requires_grad=False, dtype=torch.bfloat16), {}
        else:
            return torch.randn(shape, requires_grad=False, dtype=torch.float16), {}
    elif prec == 8:
        sign = torch.randint(0, 2, shape, requires_grad=False, dtype=torch.uint8)  # -1 or 1
        exponent = torch.randint(0, 16, shape, requires_grad=False, dtype=torch.uint8)  # < 0b01111
        mantissa = torch.randint(0, 4, shape, requires_grad=False, dtype=torch.uint8)  # can be arbitrary
        bits = {'sign': sign, 'exponent': exponent, 'mantissa': mantissa}
        # TODO: not actually correct
        return ((-1.0)**sign.double())*(2.0**(exponent.double()-15.0))*(1.0 + mantissa.double() / (2**2)), bits

def zero_data_generator(shape, prec, alt=False):
    if prec == 64:
        return torch.zeros(shape, requires_grad=False, dtype=torch.float64), {}
    elif prec == 32:
        return torch.zeros(shape, requires_grad=False, dtype=torch.float32), {}
    elif prec == 16:
        if alt:
            return torch.zeros(shape, requires_grad=False, dtype=torch.bfloat16), {}
        else:
            return torch.zeros(shape, requires_grad=False, dtype=torch.float16), {}
    elif prec == 8:
        sign = torch.zeros(0, 2, shape, requires_grad=False, dtype=torch.uint8)  # -1 or 1
        exponent = torch.zeros(0, 16, shape, requires_grad=False, dtype=torch.uint8)  # < 0b01111
        mantissa = torch.zeros(0, 4, shape, requires_grad=False, dtype=torch.uint8)  # can be arbitrary
        bits = {'sign': sign, 'exponent': exponent, 'mantissa': mantissa}
        # TODO: not actually correct
        return ((-1.0)**sign.double())*(2.0**(exponent.double()-15.0))*(1.0 + mantissa.double() / (2**2)), bits

def fconv2d(i, f, r, CH, R, C, F, dtype):
    for ch in range(CH):
    #   r += scipy.signal.convolve2d(np.flip(f.tolist()[ch]), i[ch], 'valid')
    #   r += scipy.signal.correlate2d(i[ch], f.tolist()[ch], 'valid')
      r += scipy.signal.correlate2d(i[ch], f.tolist()[ch], mode='valid')
    #   r += scipy.signal.convolve2d(i[ch], f.tolist()[ch], mode='valid')    
    return r;

# def fconv2d(i, f, r, CH, R, C, F, dtype):
#     print(f"\n=== fconv2d Debug ===")
#     print(f"Input shape: {i.shape}")  
#     print(f"Filter shape: {f.shape}")
#     print(f"Output shape should be: ({R}, {C})")
    
#     for ch in range(CH):
#         print(f"\nChannel {ch}:")
#         print(f"Input channel shape: {i[ch].shape}")
#         print(f"Filter channel shape: {f[ch].shape}")
        
#         # 打印 filter 的前几个元素（十六进制，安全）
#         print(f"Filter (first 5 in hex):")
#         for idx in range(5):
#             row = idx // F
#             col = idx % F
#             if row < 3:  # 只看前3行
#                 val = float(f[ch][row, col])
#                 print(f"  f[{row},{col}] (index {idx}): {float_to_hex(val)}")
        
#         # 尝试三种方法
#         result1 = scipy.signal.correlate2d(i[ch], f.tolist()[ch], mode='valid')
#         result2 = scipy.signal.correlate2d(i[ch], np.array(f.tolist()[ch]).T, mode='valid')
#         result3 = scipy.signal.convolve2d(i[ch], f.tolist()[ch], mode='valid')
        
#         # 打印三种方法的结果（十六进制）
#         for idx, (result, name) in enumerate([(result1, 'correlate'), 
#                                                 (result2, 'correlate+T'), 
#                                                 (result3, 'convolve')], 1):
#             val = float(result[0,0])
#             print(f"Result{idx} ({name:12s}) [0,0]: {float_to_hex(val)}")
        
#         # 使用方法1（你可以改成 result2 或 result3 测试）
#         r += result1
    
#     print(f"\nFinal output shape: {r.shape}")
#     val = float(r[0,0])
#     print(f"Output [0,0]: {float_to_hex(val)}")
#     return r

def zero_pad(a, CH, R, C, F):
    for ch in range(CH):
      for j in range(int((F - 1) / 2)):
        for i in range(R):
            a[ch][i][j]     = 0
            a[ch][i][C-1-j] = 0
      for i in range(int((F - 1) / 2)):
        for j in range(C):
            a[ch][i][j]     = 0
            a[ch][R-1-i][j] = 0
    return a

def main():

    parser = argparse.ArgumentParser(description='Generate data for kernels')
    parser.add_argument(
        "-c",
        "--cfg",
        type=pathlib.Path,
        required=True,
        help='Select param config file kernel'
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action='store_true',
        help='Set verbose'
    )

    args = parser.parse_args()

    global verbose
    verbose = args.verbose

    with args.cfg.open() as f:
        param = hjson.loads(f.read())

    if param['prec'] == 64:
        dtype = torch.float64
    elif param['prec'] == 16:
        dtype = torch.float16
    elif param['prec'] == 8:
        dtype = None
    else:
        dtype = torch.float32
    
    CORES = param['core']

    # 生成数据
    vec_I, bits_I = rand_data_generator((param['CH'], param['R']+(param['F']-1), param['C']+(param['F']-1)), param['prec'])
    vec_F, bits_F = rand_data_generator((param['CH'], param['F'], param['F']), param['prec'])

    # print("\n!!! TESTING WITH ALL ONES !!!")
    # vec_I = torch.ones((param['CH'], param['R']+(param['F']-1), param['C']+(param['F']-1)), dtype=torch.float32)
    # vec_F = torch.ones((param['CH'], param['F'], param['F']), dtype=torch.float32)
    # bits_I = {}
    # bits_F = {}
    
    vec_R, bits_R = zero_data_generator((param['R'], param['C']), param['prec'])
    vec_GR, bits_GR = zero_data_generator((param['R'], param['C']), param['prec'])
    # Pad the images internally
    vec_I = zero_pad(vec_I, param['CH'], param['R']+(param['F']-1), param['C']+(param['F']-1), param['F']);

    
    vec_F_T = vec_F.transpose(1, 2)

    # # 在 emit_header_file 之前添加调试
    # print("\n=== DEBUG: Data to be written to .h file ===")
    # print(f"vec_F shape: {vec_F.shape}")
    # print(f"vec_F.transpose(1,2) shape: {vec_F.transpose(1, 2).shape}")
    
    # # 打印原始 vec_F 的前10个元素
    # print("\nOriginal vec_F (first 10 flattened):")
    # flat_original = vec_F.flatten()
    # for i in range(min(10, len(flat_original))):
    #     print(f"  vec_F.flat[{i}] = {float_to_hex(flat_original[i])}")
    
    # # 打印转置后的 vec_F 的前10个元素（这才是真正要保存的）
    # print("\nTransposed vec_F (what will be saved, first 10 flattened):")
    # # vec_F_T = vec_F.transpose(1, 2)
    # flat_transposed = vec_F_T.flatten()
    # for i in range(min(10, len(flat_transposed))):
    #     print(f"  vec_F_T.flat[{i}] = {float_to_hex(flat_transposed[i])}")
    
    # Fconv2d
    vec_GR = fconv2d(vec_I, vec_F_T, vec_GR, param['CH'], param['R'], param['C'], param['F'], param['prec'])

    kwargs = {
      'imtx': vec_I,
      'fmtx': vec_F_T,
      'rmtx': vec_R,
      'grmtx': vec_GR,
      'CH': param['CH'],
      'R': param['R'],
      'C': param['C'],
      'F': param['F'],
      'r_dim_core': param['r_dim_core'],
      'c_dim_core': param['c_dim_core'],
      'cores': CORES,
      'prec': param['prec'],
      'expand': param['expand'],
      'bits_I': bits_I,
      'bits_F': bits_F
    }

    emit_header_file('fconv2d', **kwargs)

     # ========== 在这里添加 VERIFY ==========
    print("\n" + "="*60)
    print("=== VERIFY: What was ACTUALLY saved to .h file ===")
    print("="*60)
    
    saved_filter = kwargs['fmtx']
    print(f"\nFilter shape: {saved_filter.shape}")
    
    flat_filter = saved_filter.flatten()
    print(f"\nFirst 10 elements of fconv2d_F_dram (flattened):")
    for i in range(min(10, len(flat_filter))):
        val = float(flat_filter[i])
        print(f"  fconv2d_F_dram[{i}] = {float_to_hex(val)}")
    
    saved_golden = kwargs['grmtx']
    flat_golden = saved_golden.flatten()
    print(f"\nFirst 5 elements of fconv2d_GR_dram:")
    for i in range(min(5, len(flat_golden))):
        val = float(flat_golden[i])
        print(f"  fconv2d_GR_dram[{i}] = {float_to_hex(val)}")
    
    print("\n" + "="*60)
    print("Compare with C output:")
    print("  C read fconv2d_F_dram[0] = 0x3f2d5fbd")
    print("  C read fconv2d_F_dram[1] = 0x3ef3fea5")
    print("  C read fconv2d_F_dram[2] = 0xbf6a0a92")
    print("="*60)
    # ========================================

if __name__ == '__main__':
    main()