#!/usr/bin/env python3
"""
RMSNorm Test Vector Generator

Generates input data, gamma weights, and expected outputs for
hardware verification of the RMSNorm accelerator.

Output files (per dimension):
  - input_data_{dim}.mem           : Int32 input values (hex)
  - gamma_weights_{dim}.mem        : FP32 gamma values (hex)  
  - expected_output_{dim}.mem      : Int8 expected outputs (hex)
  - expected_output_bf16_{dim}.mem : BF16 expected outputs (hex)

Usage:
  python generate_test_vectors.py                    # Generate all dimensions
  python generate_test_vectors.py --dim 1152         # Generate specific dimension
  python generate_test_vectors.py --sweep            # Generate all standard dims
"""

import argparse
import numpy as np
import struct
import os

# Standard RMSNorm dimensions for different models
STANDARD_DIMS = {
    64:    "Small Test",
    1152:  "Custom / Mobile",
    2048:  "Gemma-2B",
    3072:  "Gemma-7B",
    4096:  "LLaMA-3-8B / LLaMA-2-7B / Mistral-7B",
    5120:  "LLaMA-2-13B / LLaMA-13B",
    6144:  "Falcon-40B",
    8192:  "LLaMA-3-70B / Mixtral 8x7B",
    12288: "GPT-3 (175B) / Grok-1"
}

def float_to_hex(f):
    """Convert float32 to hex string (IEEE 754)"""
    return format(struct.unpack('>I', struct.pack('>f', float(f)))[0], '08x')

def int32_to_hex(i):
    """Convert signed int32 to hex string (two's complement)"""
    val = int(i)
    if val < 0:
        val = val + (1 << 32)
    return format(val, '08x')

def int8_to_hex(i):
    """Convert signed int8 to hex string (two's complement)"""
    val = int(i)
    if val < 0:
        val = val + 256
    return format(val, '02x')

def float32_to_bf16_hex(f):
    """Convert float32 to BF16 hex string (truncate lower 16 bits)"""
    # Get FP32 bits
    fp32_bits = struct.unpack('>I', struct.pack('>f', float(f)))[0]
    # BF16 is upper 16 bits of FP32
    bf16_bits = (fp32_bits >> 16) & 0xFFFF
    return format(bf16_bits, '04x')

def rms_norm(x, gamma, eps=1e-5):
    """
    RMS Normalization: y = x / sqrt(mean(x^2) + eps) * gamma
    Returns both Int8 (quantized) and FP32 (for BF16 conversion) outputs
    """
    x_float = x.astype(np.float32)
    mean_sq = np.mean(x_float ** 2)
    rms = np.sqrt(mean_sq + eps)
    normalized = (x_float / rms) * gamma
    output_fp32 = normalized.astype(np.float32)
    output_int8 = np.clip(np.round(normalized), -128, 127).astype(np.int8)
    return output_int8, output_fp32, rms

def generate_test_vectors(dim, seed=42, output_dir='.', model_name=""):
    """Generate test vectors for a given dimension"""
    np.random.seed(seed)
    
    if not model_name:
        model_name = STANDARD_DIMS.get(dim, "Custom")
    
    print(f"\n{'='*60}")
    print(f"  Generating: dim={dim} ({model_name})")
    print(f"{'='*60}")
    
    # Generate input data (Int32, pattern matching testbench)
    input_data = np.array([(i % 101) - 50 for i in range(dim)], dtype=np.int32)
    
    # Generate gamma weights (FP32, cycling pattern)
    gamma_values = [0.5, 1.0, 1.5, 2.0]
    gamma = np.array([gamma_values[i % 4] for i in range(dim)], dtype=np.float32)
    
    # Compute expected output
    expected_int8, expected_fp32, rms = rms_norm(input_data, gamma)
    
    # Statistics
    print(f"  Input range:  [{input_data.min()}, {input_data.max()}]")
    print(f"  Gamma range:  [{gamma.min():.1f}, {gamma.max():.1f}]")
    print(f"  RMS value:    {rms:.6f}")
    print(f"  InvRMS:       {1.0/rms:.6f}")
    print(f"  Output range (Int8): [{expected_int8.min()}, {expected_int8.max()}]")
    print(f"  Output range (FP32): [{expected_fp32.min():.4f}, {expected_fp32.max():.4f}]")
    
    # Create output directory if needed
    os.makedirs(output_dir, exist_ok=True)
    
    # File names with dimension suffix
    input_file = f"{output_dir}/input_data_{dim}.mem"
    input_int8_file = f"{output_dir}/input_data_int8_{dim}.mem"
    gamma_file = f"{output_dir}/gamma_weights_{dim}.mem"
    output_file = f"{output_dir}/expected_output_{dim}.mem"
    output_bf16_file = f"{output_dir}/expected_output_bf16_{dim}.mem"
    meta_file = f"{output_dir}/test_metadata_{dim}.txt"
    
    # Write input_data.mem
    with open(input_file, 'w') as f:
        f.write(f"// RMSNorm input data: dim={dim} ({model_name})\n")
        f.write(f"// Format: Int32 hex, one value per line\n")
        for val in input_data:
            f.write(f"{int32_to_hex(val)}\n")
    print(f"  Written: {input_file}")
    
    # Write input_data_int8.mem (INT8 format for INT8 input precision testing)
    # Clamp values to INT8 range and write as 2-hex-digit format
    input_int8 = np.clip(input_data, -128, 127).astype(np.int8)
    with open(input_int8_file, 'w') as f:
        f.write(f"// RMSNorm input data (INT8): dim={dim} ({model_name})\n")
        f.write(f"// Format: Int8 hex, one value per line\n")
        for val in input_int8:
            f.write(f"{int8_to_hex(val)}\n")
    print(f"  Written: {input_int8_file}")
    
    # Write gamma_weights.mem
    with open(gamma_file, 'w') as f:
        f.write(f"// RMSNorm gamma weights: dim={dim}\n")
        f.write(f"// Format: FP32 hex (IEEE 754), one value per line\n")
        for val in gamma:
            f.write(f"{float_to_hex(val)}\n")
    print(f"  Written: {gamma_file}")
    
    # Write expected_output.mem (Int8)
    with open(output_file, 'w') as f:
        f.write(f"// RMSNorm expected output (Int8): dim={dim}\n")
        f.write(f"// Format: Int8 hex, one value per line\n")
        f.write(f"// RMS={rms:.6f}, InvRMS={1.0/rms:.6f}\n")
        for val in expected_int8:
            f.write(f"{int8_to_hex(val)}\n")
    print(f"  Written: {output_file}")
    
    # Write expected_output_bf16.mem (BF16)
    with open(output_bf16_file, 'w') as f:
        f.write(f"// RMSNorm expected output (BF16): dim={dim}\n")
        f.write(f"// Format: BF16 hex, one value per line\n")
        f.write(f"// RMS={rms:.6f}, InvRMS={1.0/rms:.6f}\n")
        for val in expected_fp32:
            f.write(f"{float32_to_bf16_hex(val)}\n")
    print(f"  Written: {output_bf16_file}")
    
    # Write metadata
    with open(meta_file, 'w') as f:
        f.write(f"model_name={model_name}\n")
        f.write(f"dim={dim}\n")
        f.write(f"seed={seed}\n")
        f.write(f"rms={rms:.10f}\n")
        f.write(f"inv_rms={1.0/rms:.10f}\n")
        f.write(f"epsilon=1e-5\n")
        f.write(f"input_range=[{input_data.min()}, {input_data.max()}]\n")
        f.write(f"output_int8_range=[{expected_int8.min()}, {expected_int8.max()}]\n")
        f.write(f"output_fp32_range=[{expected_fp32.min():.4f}, {expected_fp32.max():.4f}]\n")
    print(f"  Written: {meta_file}")
    
    return input_data, gamma, expected_int8, expected_fp32

def generate_all_dimensions(output_dir='./golden_mem', seed=42):
    """Generate test vectors for all standard dimensions"""
    print("\n" + "#"*60)
    print("#  RMSNorm Test Vector Generator - All Dimensions")
    print("#"*60)
    
    results = {}
    for dim, model_name in STANDARD_DIMS.items():
        generate_test_vectors(dim, seed, output_dir, model_name)
        results[dim] = model_name
    
    # Create master index file
    index_file = f"{output_dir}/test_index.txt"
    with open(index_file, 'w') as f:
        f.write("# RMSNorm Test Vector Index\n")
        f.write("# Generated files for each dimension\n\n")
        for dim, model in STANDARD_DIMS.items():
            f.write(f"dim={dim} model={model}\n")
            f.write(f"  input_data_{dim}.mem (INT32 input)\n")
            f.write(f"  input_data_int8_{dim}.mem (INT8 input)\n")
            f.write(f"  gamma_weights_{dim}.mem\n")
            f.write(f"  expected_output_{dim}.mem (INT8 output)\n")
            f.write(f"  expected_output_bf16_{dim}.mem (BF16 output)\n")
            f.write(f"  test_metadata_{dim}.txt\n\n")
    
    print(f"\n{'='*60}")
    print(f"  All test vectors generated successfully!")
    print(f"  Index: {index_file}")
    print(f"{'='*60}")
    
    # Summary table
    print("\n  Summary:")
    print("  " + "-"*50)
    print(f"  {'Dimension':<12} {'Model':<15} {'Files':<20}")
    print("  " + "-"*50)
    for dim, model in STANDARD_DIMS.items():
        print(f"  {dim:<12} {model:<15} *_{dim}.mem")
    print("  " + "-"*50)
    print(f"  Total: {len(STANDARD_DIMS)} dimensions, {len(STANDARD_DIMS)*6} files")

def main():
    parser = argparse.ArgumentParser(description='RMSNorm Test Vector Generator')
    parser.add_argument('--dim', type=int, default=None,
                        help='Vector dimension (default: generate all)')
    parser.add_argument('--seed', type=int, default=42,
                        help='Random seed (default: 42)')
    parser.add_argument('--output-dir', type=str, default='./golden_mem',
                        help='Output directory for .mem files')
    parser.add_argument('--sweep', action='store_true',
                        help='Generate all standard dimensions')
    
    args = parser.parse_args()
    
    if args.dim is not None:
        # Generate specific dimension
        generate_test_vectors(args.dim, args.seed, args.output_dir)
    else:
        # Generate all standard dimensions
        generate_all_dimensions(args.output_dir, args.seed)

if __name__ == '__main__':
    main()
