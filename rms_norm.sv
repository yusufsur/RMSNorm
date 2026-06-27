`timescale 1ns / 1ps

///////////////////////////////////////////////////////////////////////////////
// RMSNorm Accelerator
//
// Description:
//   Hardware accelerator for RMS Normalization used in Transformer models.
//   Implements: output[i] = (input[i] / sqrt(mean(x^2) + epsilon)) * gamma[i]
//
//   Architecture:
//     - NUM_LANES parallel lanes matched to 256-bit AXI bus
//     - Mixed precision: configurable input --> FP32 compute --> configurable output
//     - Ping-Pong Buffering: Decoupled Input/Output FSMs for high throughput
//
//   Input Precision (INPUT_PRECISION parameter):
//     - "INT32": 32-bit signed integer (8 values per 256-bit beat)
//     - "INT8":  8-bit signed integer (32 values per 256-bit beat)
//
//   Output Precision (PRECISION parameter):
//     - "INT8": 8-bit signed integer with saturation [-128, 127]
//     - "BF16": 16-bit bfloat16 (with round-to-nearest-even)
//
// Engineer     : Yusuf SUR
///////////////////////////////////////////////////////////////////////////////

import fp_pkg::*;

module rms_norm #(
    parameter MAX_VECTOR_SIZE   = 1152,
    parameter NUM_LANES         = 8,
    parameter DATA_WIDTH        = 256,
    parameter USE_DSP           = 1,   // 0 = Wallace Tree, 1 = DSP48E2 for multipliers
    parameter DEBUG             = 0,   // Set to 1 to enable verbose debug displays
    parameter DEBUG_CYCLES      = 0,   // Set to 1 to show only cycle breakdown at end
    parameter DEBUG_FIFO_DEPTH  = 0,   // Set to 1 to show backpressure credits
    parameter ENABLE_COVERAGE   = 0,   // Set to 1 to enable functional coverage
    parameter INPUT_PRECISION   = "INT32",  // "INT32" or "INT8" input
    parameter PRECISION         = "BF16",   // "INT8" or "BF16" output
    parameter MODEL_FAMILY      = "LLAMA"   // "LLAMA", "QWEN", "GEMMA"
  )(
    input  logic                     clk,
    input  logic                     rst_n,

    // AXI-Stream Slave Interface
    input  logic [DATA_WIDTH-1:0]    s_axis_tdata,
    input  logic                     s_axis_tvalid,
    output logic                     s_axis_tready,
    input  logic                     s_axis_tlast,

    // AXI-Stream Master Interface
    output logic [DATA_WIDTH-1:0]    m_axis_tdata,
    output logic                     m_axis_tvalid,
    input  logic                     m_axis_tready,
    output logic                     m_axis_tlast,

    // Control/Status Interface
    input  logic                     start,
    output logic                     done,
    output logic                     busy,

    // Configuration
    input  logic [31:0]              cfg_epsilon,

    // Gamma Weight Memory Interface
    input  logic                     gamma_we_wide,
    input  logic [15:0]              gamma_addr_wide,
    input  logic [DATA_WIDTH-1:0]    gamma_wdata_wide,
    output logic                     gamma_busy
  );

  //===========================================================================
  // Local Parameters
  //===========================================================================
  localparam FIFO_DEPTH     = MAX_VECTOR_SIZE;
  localparam FIFO_ADDR_W    = $clog2(FIFO_DEPTH);
  localparam FP32_WIDTH     = 32;
  localparam FP32_ONE       = 32'h3F800000;

  // Number of interleaved accumulators = FP adder latency + 1
  // Need +1 to avoid feedback hazard when consecutive accesses overlap
  localparam NUM_ACCUMULATORS = FP_ADD_LATENCY + 1;

  // Input precision: INT32 = 32 bits, INT8 = 8 bits
  localparam INPUT_BITS = (INPUT_PRECISION == "INT8") ? 8 : 32;
  localparam INPUT_PACK_SIZE = DATA_WIDTH / INPUT_BITS;  // 16 for INT32@512b, 64 for INT8@512b

  // Output precision: INT8 = 8 bits, BF16 = 16 bits
  localparam OUTPUT_BITS = (PRECISION == "BF16") ? 16 : 8;

  //===========================================================================
  // Parameter Validation (compile-time)
  //===========================================================================
  generate
    if (INPUT_PRECISION != "INT8" && INPUT_PRECISION != "INT32")
      $fatal(1, "RMSNorm: INPUT_PRECISION must be \"INT8\" or \"INT32\", got \"%s\"", INPUT_PRECISION);
    if (PRECISION != "BF16" && PRECISION != "INT8")
      $fatal(1, "RMSNorm: PRECISION must be \"BF16\" or \"INT8\", got \"%s\"", PRECISION);
    if (NUM_LANES * INPUT_BITS > DATA_WIDTH)
      $fatal(1, "RMSNorm: DATA_WIDTH=%0d too narrow for NUM_LANES=%0d x INPUT_BITS=%0d (%0d bits required). All lanes must be fed in a single beat.",
             DATA_WIDTH, NUM_LANES, INPUT_BITS, NUM_LANES * INPUT_BITS);
    if (NUM_LANES * 32 > DATA_WIDTH)
      $fatal(1, "RMSNorm: DATA_WIDTH=%0d too narrow for gamma memory write: NUM_LANES=%0d x 32-bit FP32 requires %0d bits.",
             DATA_WIDTH, NUM_LANES, NUM_LANES * 32);
  endgenerate

  // Output packer size depends on precision
  // INT8 output: 256/8 = 32 values per beat
  // BF16 output: 256/16 = 16 values per beat
  localparam OUTPUT_PACK_SIZE = DATA_WIDTH / OUTPUT_BITS;
  localparam PACK_BEATS = OUTPUT_PACK_SIZE / NUM_LANES;  // Varies with NUM_LANES and PRECISION

  //===========================================================================
  // FSM States
  //===========================================================================
  // Input FSM (Accumulator)
  typedef enum logic [3:0] {
            S_IN_IDLE        = 4'd0,
            S_IN_ACCUM       = 4'd1,
            S_IN_DRAIN       = 4'd2,
            S_IN_REDUCE_INIT = 4'd3,
            S_IN_REDUCE      = 4'd4
          } state_in_t;
  state_in_t state_in, state_in_next;

  // Output FSM (Normalizer)
  typedef enum logic [3:0] {
            S_OUT_IDLE       = 4'd0,
            S_OUT_WAIT_CMD   = 4'd1,
            S_OUT_CALC_MEAN  = 4'd2,
            S_OUT_CALC_INV   = 4'd3,
            S_OUT_STREAM     = 4'd4,
            S_OUT_DONE       = 4'd5
          } state_out_t;
  state_out_t state_out, state_out_next;

  //===========================================================================
  // Pipeline Shift Registers
  //===========================================================================
  localparam FP_ADD_LATENCY    = 7;   // fp_add pipeline depth
  localparam LAT_INT_FP        = 3;
  localparam LAT_FP_REG        = 1;
  localparam LAT_FP_MUL        = 5;
  localparam LAT_ADD_TREE      = $clog2(NUM_LANES) * FP_ADD_LATENCY;
  localparam LAT_ACC_ADD       = FP_ADD_LATENCY;

  // Pipeline depth = int_to_fp(3) + fp32_reg(1) + fp_mul(5) + adder_tree(3*FP_ADD_LATENCY) + acc_add(FP_ADD_LATENCY)
  localparam PIPE_DEPTH    = LAT_INT_FP + LAT_FP_REG + LAT_FP_MUL + LAT_ADD_TREE + LAT_ACC_ADD;

  //===========================================================================
  // Credit-Based Flow Control
  // Best way to prevent backpressure
  //===========================================================================
  // We need credits to prevent output FIFO overflow during backpressure.
  // The output FIFO depth is PIPE_DEPTH. We consume a credit when we start
  // producing an output (every 4 input beats = 1 output beat), and return
  // a credit when output is consumed from the output FIFO.
  //
  // Input rate = 4x Output rate due to packer, so we must
  // consume credits at the output rate, not input rate.

  //===========================================================================
  // Backpressure Credit Logic
  //===========================================================================
  // We need to catch in flight data (skid) when we stop.
  localparam FIFO_DEPTH_POW2 = 128;
  localparam CREDIT_DEPTH = (2* PIPE_DEPTH);
  localparam CW = $clog2(CREDIT_DEPTH + 1);

  logic [CW-1:0] credit_counter;
  logic          credit_available;
  logic          credit_consume;    // When we produce an output beat (every N inputs)
  logic          credit_return;     // When output is consumed
  logic [3:0]    credit_beat_cnt;   // Count input beats (0-15)

  // Calculate Ratios for Credit Control
  // PACK_BEATS = how many internal reads (fifo_re) produce one output AXI beat
  // This accounts for both:
  //                        Internal packing: NUM_LANES elements per read -> OUTPUT_PACK_SIZE per output
  //                        Precision changes: different input/output element counts per AXI beat
  //
  // For credit control, we consume credits at the OUTPUT rate, not the internal read rate.
  // INPUTS_PER_OUTPUT = number of fifo_re operations per output beat = PACK_BEATS
  localparam INPUTS_PER_OUTPUT = PACK_BEATS;  // fifo reads per output beat
  // Expansion: 1 fifo_re produces NUM_LANES elements.
  // If NUM_LANES > OUTPUT_PACK_SIZE, one read yields multiple output beats.
  // Note: INPUT_PACK_SIZE is the bus capacity, NOT the per-cycle processing width.
  //       The core always processes NUM_LANES per fifo_re regardless of input precision.
  localparam OUTPUTS_PER_INPUT = (NUM_LANES > OUTPUT_PACK_SIZE) ? (NUM_LANES / OUTPUT_PACK_SIZE) : 1;

  logic [PIPE_DEPTH-1:0] tlast_pipe;  // Shift register for tlast
  logic                  pipeline_done;  // tlast emerged from pipeline

  //===========================================================================
  // Signal Declarations
  //===========================================================================

  // Input unpacking
  logic signed [INPUT_BITS-1:0] input_lane [NUM_LANES];

  // FP32 converted inputs
  logic [FP32_WIDTH-1:0] fp32_lane [NUM_LANES];
  logic [NUM_LANES-1:0]  fp32_valid;

  // Registered FP32 inputs
  logic [FP32_WIDTH-1:0] fp32_lane_reg [NUM_LANES];
  logic [NUM_LANES-1:0]  fp32_valid_reg;

  // Squared values
  logic [FP32_WIDTH-1:0] squared_lane [NUM_LANES];
  logic [NUM_LANES-1:0]  squared_valid;

  // Adder tree results
  // Adder tree results
  localparam LOG_LANES = $clog2(NUM_LANES);
  logic [FP32_WIDTH-1:0] tree_data  [LOG_LANES+1][NUM_LANES];
  logic                  tree_valid [LOG_LANES+1][NUM_LANES];

  // Final result alias (matches existing downstream logic)
  logic [FP32_WIDTH-1:0] sum_stage3;
  logic                  sum_valid_s3;

  // Interleaved accumulators
  logic [FP32_WIDTH-1:0] partial_acc [NUM_ACCUMULATORS];
  logic [$clog2(NUM_ACCUMULATORS)-1:0] acc_sel;  // Round robin selector
  logic [FP32_WIDTH-1:0] acc_input_a;
  logic [FP32_WIDTH-1:0] acc_input_b;
  logic [FP32_WIDTH-1:0] acc_result;
  logic                  acc_valid_in;
  logic                  acc_valid_out;

  // Final accumulated sum
  logic [FP32_WIDTH-1:0] total_sum;

  // Reduction stage
  logic [$clog2(NUM_ACCUMULATORS):0] reduce_idx;
  logic [FP32_WIDTH-1:0] reduce_acc;
  logic                  reduce_done;
  logic [2:0]            reduce_init_cnt;  // Counter to wait for last acc update

  // Mean and normalization
  logic [FP32_WIDTH-1:0] inv_rms;
  logic                  inv_rms_valid;

  // Division and fast inverse sqrt
  logic [FP32_WIDTH-1:0] n_fp32;
  logic                  div_mean_valid, div_mean_busy;
  logic [FP32_WIDTH-1:0] div_mean_result;
  logic                  fast_inv_sqrt_valid;
  logic [FP32_WIDTH-1:0] fast_inv_sqrt_result;

  // Control
  logic [15:0]           element_count;
  logic [15:0]           output_count;
  logic                  fifo_we, fifo_re;
  logic [FIFO_ADDR_W-1:0] fifo_wptr, fifo_rptr;
  logic [15:0]           gamma_rd_addr;

  // Replay FIFO banks
  localparam REPLAY_BANK_DEPTH = FIFO_DEPTH / NUM_LANES;

  logic [INPUT_BITS-1:0] replay_data_raw [NUM_LANES];

  // Gamma weight memory output
  logic [FP32_WIDTH-1:0] gamma_lane [NUM_LANES];
  logic [FP32_WIDTH-1:0] gamma_raw [NUM_LANES];

  // Output pipeline
  logic [FP32_WIDTH-1:0] norm_lane [NUM_LANES];
  logic [NUM_LANES-1:0]  norm_valid;
  logic [FP32_WIDTH-1:0] gamma_scaled [NUM_LANES];
  logic [NUM_LANES-1:0]  gamma_valid;
  logic [OUTPUT_BITS-1:0] output_quant [NUM_LANES];  // INT8 or BF16
  logic [NUM_LANES-1:0]  quant_valid;

  // Output packer (accumulate PACK_BEATS for full 256-bit utilization)
  logic [OUTPUT_BITS-1:0] output_pack_buf [OUTPUT_PACK_SIZE];
  logic [$clog2(PACK_BEATS)-1:0] pack_beat_cnt;

  //===========================================================================
  // Input Unpacking (DATA_WIDTH-bit -> NUM_LANES x INPUT_BITS)
  // Full utilization guaranteed by parameter validation above
  //===========================================================================
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_unpack
      assign input_lane[i] = s_axis_tdata[i*INPUT_BITS +: INPUT_BITS];
    end
  endgenerate

  //===========================================================================
  // Int to FP32 Converters (NUM_LANES instances)
  //===========================================================================
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_int_to_fp
      int_to_fp #(
                  .INT_WIDTH(INPUT_BITS),
                  .FP_WIDTH(FP32_WIDTH),
                  .EXP_WIDTH(8),
                  .MAN_WIDTH(23)
                ) u_int_to_fp (
                  .clk(clk),
                  .rst_n(rst_n),
                  .int_in(input_lane[i]),
                  .valid_in(s_axis_tvalid && s_axis_tready && (state_in == S_IN_ACCUM)),
                  .fp_out(fp32_lane[i]),
                  .valid_out(fp32_valid[i]),
                  .flags()
                );
    end
  endgenerate

  //===========================================================================
  // Pipeline registers for FP32
  //===========================================================================
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        fp32_lane_reg[i] <= 0;
      end
      fp32_valid_reg <= 0;
    end
    else
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        fp32_lane_reg[i] <= fp32_lane[i];
      end
      fp32_valid_reg <= fp32_valid;
    end
  end

  //===========================================================================
  // FP32 Squaring (NUM_LANES multipliers: x * x)
  //===========================================================================
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_square
      fp_mul #(
               .FP_WIDTH(FP32_WIDTH),
               .EXP_WIDTH(8),
               .MAN_WIDTH(23),
               .USE_DSP(USE_DSP)
             ) u_square (
               .clk(clk),
               .rst_n(rst_n),
               .a(fp32_lane_reg[i]),
               .b(fp32_lane_reg[i]),
               .valid_in(fp32_valid_reg[i]),
               .result(squared_lane[i]),
               .valid_out(squared_valid[i]),
               .flags()
             );
    end
  endgenerate

  //===========================================================================
  // Adder Tree, NUM_LANES -> 1 Pipelined Global Sum
  //===========================================================================

  // Assign level 0
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_tree_input
      assign tree_data[0][i]  = squared_lane[i];
      assign tree_valid[0][i] = squared_valid[i];
    end
  endgenerate

  // Generate recursive tree stages
  generate
    for (genvar lvl = 0; lvl < LOG_LANES; lvl++)
    begin : gen_tree_stage
      for (genvar k = 0; k < (NUM_LANES >> (lvl + 1)); k++)
      begin : gen_tree_node
        fp_add #(
                 .FP_WIDTH(FP32_WIDTH),
                 .EXP_WIDTH(8),
                 .MAN_WIDTH(23)
               ) u_tree_add (
                 .clk(clk),
                 .rst_n(rst_n),
                 .a(tree_data[lvl][2*k]),
                 .b(tree_data[lvl][2*k+1]),
                 .valid_in(tree_valid[lvl][2*k] && tree_valid[lvl][2*k+1]),
                 .result(tree_data[lvl+1][k]),
                 .valid_out(tree_valid[lvl+1][k]),
                 .flags()
               );
      end
    end
  endgenerate

  // Output Assignment
  assign sum_stage3   = tree_data[LOG_LANES][0];
  assign sum_valid_s3 = tree_valid[LOG_LANES][0];

  //===========================================================================
  // Accumulators
  //===========================================================================
  // Sweep through them, each gets a new value every N cycles
  // Accumulator selector
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      acc_sel <= 0;
    end
    else if (state_in == S_IN_IDLE && start)
    begin
      acc_sel <= 0;
    end
    else if (sum_valid_s3)
    begin
      if (acc_sel == NUM_ACCUMULATORS - 1)
        acc_sel <= 0;
      else
        acc_sel <= acc_sel + 1;
    end
  end

  // Select which accumulator to update
  assign acc_input_a = sum_stage3;
  assign acc_input_b = partial_acc[acc_sel];
  assign acc_valid_in = sum_valid_s3;

  // Accumulator adder
  fp_add #(
           .FP_WIDTH(FP32_WIDTH),
           .EXP_WIDTH(8),
           .MAN_WIDTH(23)
         ) u_acc_add (
           .clk(clk),
           .rst_n(rst_n),
           .a(acc_input_a),
           .b(acc_input_b),
           .valid_in(acc_valid_in),
           .result(acc_result),
           .valid_out(acc_valid_out),
           .flags()
         );

  // Delay acc_sel to match adder latency
  logic [$clog2(NUM_ACCUMULATORS)-1:0] acc_sel_delayed [FP_ADD_LATENCY];

  always_ff @(posedge clk)
  begin
    acc_sel_delayed[0] <= acc_sel;
    for (int i = 1; i < FP_ADD_LATENCY; i++)
    begin
      acc_sel_delayed[i] <= acc_sel_delayed[i-1];
    end
  end

  // Update partial accumulators
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      for (int i = 0; i < NUM_ACCUMULATORS; i++)
      begin
        partial_acc[i] <= 0;
      end
    end
    else if (state_in == S_IN_IDLE && start)
    begin
      for (int i = 0; i < NUM_ACCUMULATORS; i++)
      begin
        partial_acc[i] <= 0;
      end
    end
    else if (acc_valid_out)
    begin
      partial_acc[acc_sel_delayed[FP_ADD_LATENCY-1]] <= acc_result;
    end
  end

  //===========================================================================
  // Handoff FIFO passes results from input FSM to output FSM
  //===========================================================================
  // Payload {Total Sum (32b), Vector Length (16b)}

  // Handoff Signals ping pong
  logic        handoff_push;
  logic        handoff_pop;
  logic        handoff_full;
  logic        handoff_empty;
  logic [47:0] handoff_din;
  logic [47:0] handoff_dout;
  logic [31:0] current_total_sum;
  logic [15:0] current_vector_len;

  logic [31:0] total_sum_reg;
  logic [15:0] vector_len_reg;

  fifo #(
         .DATA_WIDTH(48),
         .DEPTH(32)
       ) u_handoff_fifo (
         .clk(clk),
         .rst_n(rst_n), // Active low reset
         .wr_en(handoff_push),
         .wr_data(handoff_din),
         .full(handoff_full),
         .rd_en(handoff_pop),
         .rd_data(handoff_dout),
         .empty(handoff_empty)
       );
  // Pack data for handoff
  // total_sum (32) + element_count (16) = 48 bits
  assign handoff_din = {total_sum, element_count};
  // Trigger push when Input FSM finishes reduction
  assign handoff_push = (state_in == S_IN_REDUCE && reduce_done);
  // Pop immediately when we accept the job at IDLE
  // This allows the FIFO to fill with the next job while we process the current one.
  assign handoff_pop = (state_out == S_OUT_IDLE && !handoff_empty);

  // Latch the FIFO output when we are in WAIT_CMD state
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      total_sum_reg <= 0;
      vector_len_reg <= 0;
    end
    else if (state_out == S_OUT_WAIT_CMD)
    begin
      total_sum_reg <= handoff_dout[47:16];
      vector_len_reg <= handoff_dout[15:0];
    end
  end
  //===========================================================================
  // Reduction, sum all partial accumulators using fp_add
  // Pipelined Tree Reduction for Partial Accumulators
  //===========================================================================
  // Latency, 3 * FP_ADD_LATENCY
  // Level 1, 0+1, 2+3, 4+5, 6+7
  // Level 2, L1_0+L1_1, L1_2+L1_3
  // Level 3, L2_0+L2_1 -> Total

  logic [FP32_WIDTH-1:0] tree_l1 [4];
  logic [FP32_WIDTH-1:0] tree_l2 [2];
  logic [FP32_WIDTH-1:0] tree_l3_total;
  logic [3:0]            tree_l1_valid;
  logic [1:0]            tree_l2_valid;
  logic                  tree_l3_valid;
  logic                  reduce_in_progress;
  // Start signal when we enter ST_REDUCE, the partial accumulators are stable
  // (after waiting for ST_REDUCE_INIT). We pulse valid ONCE.
  logic tree_start;
  assign tree_start = (state_in == S_IN_REDUCE) && !reduce_in_progress; // Pulse once at start

  // LEVEL 1 (8 -> 4)
  generate
    for (genvar i = 0; i < 4; i++)
    begin : gen_tree_l1
      fp_add #(.FP_WIDTH(FP32_WIDTH), .EXP_WIDTH(8), .MAN_WIDTH(23)) u_tree_l1 (
               .clk(clk), .rst_n(rst_n),
               .a(partial_acc[2*i]), .b(partial_acc[2*i+1]),
               .valid_in(tree_start),
               .result(tree_l1[i]), .valid_out(tree_l1_valid[i]), .flags()
             );
    end
  endgenerate

  // LEVEL 2 (4 -> 2)
  generate
    for (genvar i = 0; i < 2; i++)
    begin : gen_tree_l2
      fp_add #(.FP_WIDTH(FP32_WIDTH), .EXP_WIDTH(8), .MAN_WIDTH(23)) u_tree_l2 (
               .clk(clk), .rst_n(rst_n),
               .a(tree_l1[2*i]), .b(tree_l1[2*i+1]),
               .valid_in(tree_l1_valid[2*i]), // Wait for L1
               .result(tree_l2[i]), .valid_out(tree_l2_valid[i]), .flags()
             );
    end
  endgenerate

  // LEVEL 3 (2 -> 1)
  fp_add #(.FP_WIDTH(FP32_WIDTH), .EXP_WIDTH(8), .MAN_WIDTH(23)) u_tree_l3 (
           .clk(clk), .rst_n(rst_n),
           .a(tree_l2[0]), .b(tree_l2[1]),
           .valid_in(tree_l2_valid[0]), // Wait for L2
           .result(tree_l3_total), .valid_out(tree_l3_valid), .flags()
         );

  // Reduction FSM Control
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      reduce_done <= 1'b0;
      reduce_in_progress <= 1'b0;
      reduce_init_cnt <= 0;
      total_sum <= 0;
    end
    else if (state_in == S_IN_IDLE && start)
    begin
      reduce_done <= 1'b0;
      reduce_in_progress <= 1'b0;
      reduce_init_cnt <= 0;
    end
    else if (state_in == S_IN_REDUCE_INIT)
    begin
      // Wait for accumulators to settle
      reduce_init_cnt <= reduce_init_cnt + 1;
      if (reduce_init_cnt == FP_ADD_LATENCY)
      begin
        // Ready to transition to S_IN_REDUCE
        reduce_done <= 1'b0;
        reduce_in_progress <= 1'b0; // Will trigger tree_start next cycle
      end
    end
    else if (state_in == S_IN_REDUCE)
    begin
      // Kick off Logic (Combinatorial tree_start=1 when reduce_in_progress=0)
      if (!reduce_in_progress)
        reduce_in_progress <= 1'b1; // Mark as started so we don't restart

      // Wait for result
      if (tree_l3_valid)
      begin
        total_sum <= tree_l3_total;
        reduce_done <= 1'b1;
      end
    end
  end

  //===========================================================================
  // Replay Memory Double Buffered
  //===========================================================================
  // We use NUM_LANES dpram instances (1 per lane)
  // Double buffering is handled by address MSB (Page bit)
  // Address Width log2(REPLAY_BANK_DEPTH) + 1 (for page bit)

  localparam DPRAM_ADDR_W = $clog2(REPLAY_BANK_DEPTH) + 1;
  logic [INPUT_BITS-1:0] replay_rdata [NUM_LANES];
  logic wr_page; // Current write page
  logic rd_page; // Current read page

  generate
    for(genvar i=0; i<NUM_LANES; i++)
    begin : gen_replay_mem
      dpram #(
              .A_WID(DPRAM_ADDR_W),
              .D_WID(INPUT_BITS)
            ) u_replay_ram (
              .clka(clk),
              .clkb(clk),
              .wea(fifo_we),
              .web(1'b0),     // Port B is read only
              .ena(1'b1),
              .enb(fifo_re),  // Enable read when reading
              .addra({wr_page, fifo_wptr[$clog2(REPLAY_BANK_DEPTH)-1:0]}), // Page + Ptr
              .addrb({rd_page, fifo_rptr[$clog2(REPLAY_BANK_DEPTH)-1:0]}), // Page + Ptr
              .dina(input_lane[i]),
              .dinb({INPUT_BITS{1'b0}}),
              .douta(),
              .doutb(replay_data_raw[i])
            );
    end
  endgenerate

  // Page Toggling Input FSM
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
      wr_page <= 0;
    else if (handoff_push) // Toggle when input vector is complete-pushed
      wr_page <= ~wr_page;
  end

  // Page Toggling Output FSM
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
      rd_page <= 0;
    else if (state_out == S_OUT_STREAM && output_count >= vector_len_reg) // Toggle when output vector complete
      rd_page <= ~rd_page;
  end


  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      fifo_wptr <= 0;
    end
    else if (state_in == S_IN_IDLE && start)
    begin
      fifo_wptr <= 0;
    end
    else if (fifo_we)
    begin
      fifo_wptr <= fifo_wptr + 1;
    end
  end

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      fifo_rptr <= 0;
    end
    else if (state_out == S_OUT_CALC_INV && fast_inv_sqrt_valid)
    begin
      fifo_rptr <= 0;
    end
    else if (fifo_re)
    begin
      fifo_rptr <= fifo_rptr + 1;
    end
  end

  assign fifo_we = s_axis_tvalid && s_axis_tready && (state_in == S_IN_ACCUM);

  //===========================================================================
  // Stream Fed Counter
  //===========================================================================
  // Pipeline latency causes output_count to lag behind fifo reads.
  // Without this, we read N + pipeline_depth elements, garbage at end.
  logic [15:0] stream_fed_count;

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
      stream_fed_count <= 0;
    else if (state_out == S_OUT_IDLE)
      stream_fed_count <= 0;
    else if (fifo_re)
      stream_fed_count <= stream_fed_count + NUM_LANES;
  end

  // Stop reading when we fed N elements OR when no credits available
  assign fifo_re = (state_out == S_OUT_STREAM) && credit_available && (stream_fed_count < vector_len_reg);



  //===========================================================================
  // Gamma Weight Memory
  //===========================================================================
  localparam GAMMA_BANK_DEPTH = MAX_VECTOR_SIZE / NUM_LANES;

  // Gamma busy signal HIGH when gamma memory is being read
  // Gamma reads occur during S_OUT_STREAM and S_OUT_CALC_INV (while pipeline fills)
  // Block gamma writes during these states to prevent write-during-read hazards
  assign gamma_busy = (state_out == S_OUT_STREAM) || (state_out == S_OUT_CALC_INV);

  // Gated write enables - block writes when gamma is being read
  logic gamma_we_wide_gated;
  assign gamma_we_wide_gated = gamma_we_wide && !gamma_busy;

  // Unrolled BRAM banks each gets its own name for proper inference or dumbass vivado infers this memory as FFs
  generate
    if (NUM_LANES == 8)
    begin : gen_gamma_8lane
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank0 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank1 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank2 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank3 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank4 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank5 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank6 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank7 [GAMMA_BANK_DEPTH];

      // Parametric wide write for 8 lanes
      // WIDE_VALUES = DATA_WIDTH / 32 = how many FP32 values per beat
      // If DATA_WIDTH=256: 8 values/beat, write all banks at once
      // If DATA_WIDTH=512: 16 values/beat, use addr[0] to select row group
      localparam WIDE_VALUES_8 = DATA_WIDTH / 32;
      localparam NEED_TWO_ROWS = (WIDE_VALUES_8 > 8);  // Need to write 2 rows per beat if bus is wider

      // Wide write (DMA) - parametric for bus width
      always_ff @(posedge clk)
      begin
        if (gamma_we_wide_gated)
        begin
          if (NEED_TWO_ROWS)
          begin
            // 512-bit bus: 16 values per beat, write to 2 consecutive rows
            // addr_wide is the row pair index, write to row*2 and row*2+1
            // Lower 8 values (bits 0-255) go to even row
            gamma_memory_bank0[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[31:0];
            gamma_memory_bank1[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[63:32];
            gamma_memory_bank2[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[95:64];
            gamma_memory_bank3[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[127:96];
            gamma_memory_bank4[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[159:128];
            gamma_memory_bank5[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[191:160];
            gamma_memory_bank6[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[223:192];
            gamma_memory_bank7[{gamma_addr_wide, 1'b0}] <= gamma_wdata_wide[255:224];
            // Upper 8 values (bits 256-511) go to odd row
            gamma_memory_bank0[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[287:256];
            gamma_memory_bank1[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[319:288];
            gamma_memory_bank2[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[351:320];
            gamma_memory_bank3[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[383:352];
            gamma_memory_bank4[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[415:384];
            gamma_memory_bank5[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[447:416];
            gamma_memory_bank6[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[479:448];
            gamma_memory_bank7[{gamma_addr_wide, 1'b1}] <= gamma_wdata_wide[511:480];
          end
          else
          begin
            // All 8 banks guaranteed to fit (parameter validation: NUM_LANES*32 <= DATA_WIDTH)
            gamma_memory_bank0[gamma_addr_wide] <= gamma_wdata_wide[31:0];
            gamma_memory_bank1[gamma_addr_wide] <= gamma_wdata_wide[63:32];
            gamma_memory_bank2[gamma_addr_wide] <= gamma_wdata_wide[95:64];
            gamma_memory_bank3[gamma_addr_wide] <= gamma_wdata_wide[127:96];
            gamma_memory_bank4[gamma_addr_wide] <= gamma_wdata_wide[159:128];
            gamma_memory_bank5[gamma_addr_wide] <= gamma_wdata_wide[191:160];
            gamma_memory_bank6[gamma_addr_wide] <= gamma_wdata_wide[223:192];
            gamma_memory_bank7[gamma_addr_wide] <= gamma_wdata_wide[255:224];
          end
        end
      end


      always_ff @(posedge clk)
      begin
        gamma_raw[0] <= gamma_memory_bank0[gamma_rd_addr >> LOG_LANES];
        gamma_raw[1] <= gamma_memory_bank1[gamma_rd_addr >> LOG_LANES];
        gamma_raw[2] <= gamma_memory_bank2[gamma_rd_addr >> LOG_LANES];
        gamma_raw[3] <= gamma_memory_bank3[gamma_rd_addr >> LOG_LANES];
        gamma_raw[4] <= gamma_memory_bank4[gamma_rd_addr >> LOG_LANES];
        gamma_raw[5] <= gamma_memory_bank5[gamma_rd_addr >> LOG_LANES];
        gamma_raw[6] <= gamma_memory_bank6[gamma_rd_addr >> LOG_LANES];
        gamma_raw[7] <= gamma_memory_bank7[gamma_rd_addr >> LOG_LANES];
      end

    end
    else if (NUM_LANES == 16)
    begin : gen_gamma_16lane
      initial
        if (DEBUG)
          $display("[RMS_NORM] NUM_LANES=%0d, LOG_LANES=%0d", NUM_LANES, LOG_LANES);
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank0 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank1 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank2 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank3 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank4 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank5 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank6 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank7 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank8 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank9 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank10 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank11 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank12 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank13 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank14 [GAMMA_BANK_DEPTH];
      (* ram_style = "block" *) logic [31:0] gamma_memory_bank15 [GAMMA_BANK_DEPTH];

      // Parametric wide write for 16 lanes
      // WIDE_VALUES = DATA_WIDTH / 32 = how many FP32 values per beat
      // If DATA_WIDTH=512: 16 values/beat, write all banks at once
      // If DATA_WIDTH=256: 8 values/beat, use addr[0] to select bank half
      localparam WIDE_VALUES_16 = DATA_WIDTH / 32;
      localparam NEED_TWO_BEATS = (WIDE_VALUES_16 < 16);  // Need 2 beats per row if bus is narrower

      // Uses gated write enable to prevent writes during gamma reads
      always_ff @(posedge clk)
      begin
        if (gamma_we_wide_gated)
        begin
          if (NEED_TWO_BEATS)
          begin
            // 256-bit bus: 8 values per beat, addr[0] selects lower/upper half
            if (!gamma_addr_wide[0])
            begin
              // Lower half (banks 0-7)
              gamma_memory_bank0[gamma_addr_wide >> 1]  <= gamma_wdata_wide[31:0];
              gamma_memory_bank1[gamma_addr_wide >> 1]  <= gamma_wdata_wide[63:32];
              gamma_memory_bank2[gamma_addr_wide >> 1]  <= gamma_wdata_wide[95:64];
              gamma_memory_bank3[gamma_addr_wide >> 1]  <= gamma_wdata_wide[127:96];
              gamma_memory_bank4[gamma_addr_wide >> 1]  <= gamma_wdata_wide[159:128];
              gamma_memory_bank5[gamma_addr_wide >> 1]  <= gamma_wdata_wide[191:160];
              gamma_memory_bank6[gamma_addr_wide >> 1]  <= gamma_wdata_wide[223:192];
              gamma_memory_bank7[gamma_addr_wide >> 1]  <= gamma_wdata_wide[255:224];
            end
            else
            begin
              // Upper half (banks 8-15)
              gamma_memory_bank8[gamma_addr_wide >> 1]  <= gamma_wdata_wide[31:0];
              gamma_memory_bank9[gamma_addr_wide >> 1]  <= gamma_wdata_wide[63:32];
              gamma_memory_bank10[gamma_addr_wide >> 1] <= gamma_wdata_wide[95:64];
              gamma_memory_bank11[gamma_addr_wide >> 1] <= gamma_wdata_wide[127:96];
              gamma_memory_bank12[gamma_addr_wide >> 1] <= gamma_wdata_wide[159:128];
              gamma_memory_bank13[gamma_addr_wide >> 1] <= gamma_wdata_wide[191:160];
              gamma_memory_bank14[gamma_addr_wide >> 1] <= gamma_wdata_wide[223:192];
              gamma_memory_bank15[gamma_addr_wide >> 1] <= gamma_wdata_wide[255:224];
            end
          end
          else
          begin
            // 512-bit bus: write all 16 banks simultaneously
            gamma_memory_bank0[gamma_addr_wide]  <= gamma_wdata_wide[31:0];
            gamma_memory_bank1[gamma_addr_wide]  <= gamma_wdata_wide[63:32];
            gamma_memory_bank2[gamma_addr_wide]  <= gamma_wdata_wide[95:64];
            gamma_memory_bank3[gamma_addr_wide]  <= gamma_wdata_wide[127:96];
            gamma_memory_bank4[gamma_addr_wide]  <= gamma_wdata_wide[159:128];
            gamma_memory_bank5[gamma_addr_wide]  <= gamma_wdata_wide[191:160];
            gamma_memory_bank6[gamma_addr_wide]  <= gamma_wdata_wide[223:192];
            gamma_memory_bank7[gamma_addr_wide]  <= gamma_wdata_wide[255:224];
            gamma_memory_bank8[gamma_addr_wide]  <= gamma_wdata_wide[287:256];
            gamma_memory_bank9[gamma_addr_wide]  <= gamma_wdata_wide[319:288];
            gamma_memory_bank10[gamma_addr_wide] <= gamma_wdata_wide[351:320];
            gamma_memory_bank11[gamma_addr_wide] <= gamma_wdata_wide[383:352];
            gamma_memory_bank12[gamma_addr_wide] <= gamma_wdata_wide[415:384];
            gamma_memory_bank13[gamma_addr_wide] <= gamma_wdata_wide[447:416];
            gamma_memory_bank14[gamma_addr_wide] <= gamma_wdata_wide[479:448];
            gamma_memory_bank15[gamma_addr_wide] <= gamma_wdata_wide[511:480];
          end
        end
      end


      always_ff @(posedge clk)
      begin
        gamma_raw[0]  <= gamma_memory_bank0[gamma_rd_addr >> LOG_LANES];
        gamma_raw[1]  <= gamma_memory_bank1[gamma_rd_addr >> LOG_LANES];
        gamma_raw[2]  <= gamma_memory_bank2[gamma_rd_addr >> LOG_LANES];
        gamma_raw[3]  <= gamma_memory_bank3[gamma_rd_addr >> LOG_LANES];
        gamma_raw[4]  <= gamma_memory_bank4[gamma_rd_addr >> LOG_LANES];
        gamma_raw[5]  <= gamma_memory_bank5[gamma_rd_addr >> LOG_LANES];
        gamma_raw[6]  <= gamma_memory_bank6[gamma_rd_addr >> LOG_LANES];
        gamma_raw[7]  <= gamma_memory_bank7[gamma_rd_addr >> LOG_LANES];
        gamma_raw[8]  <= gamma_memory_bank8[gamma_rd_addr >> LOG_LANES];
        gamma_raw[9]  <= gamma_memory_bank9[gamma_rd_addr >> LOG_LANES];
        gamma_raw[10] <= gamma_memory_bank10[gamma_rd_addr >> LOG_LANES];
        gamma_raw[11] <= gamma_memory_bank11[gamma_rd_addr >> LOG_LANES];
        gamma_raw[12] <= gamma_memory_bank12[gamma_rd_addr >> LOG_LANES];
        gamma_raw[13] <= gamma_memory_bank13[gamma_rd_addr >> LOG_LANES];
        gamma_raw[14] <= gamma_memory_bank14[gamma_rd_addr >> LOG_LANES];
        gamma_raw[15] <= gamma_memory_bank15[gamma_rd_addr >> LOG_LANES];
      end
    end
    else
    begin
      $fatal(1, "Unsupported NUM_LANES");
    end
  endgenerate

  //===========================================================================
  // Gamma Pipeline Delay Line
  //===========================================================================

  // Latency from replay_data_raw to norm_lane:
  // int_to_fp(3) + replay_fp32_reg(1) + norm_mul(5) = 9 cycles
  localparam GAMMA_DELAY_CYCLES = 9;

  // Gemma offset: gamma_effective = gamma + 1.0 (identity offset)
  // fp_add latency = 7 cycles, so reduce delay by 7 to keep alignment
  localparam GAMMA_OFFSET_LAT     = (MODEL_FAMILY == "GEMMA") ? FP_ADD_LATENCY : 0;
  localparam GAMMA_DELAY_ADJUSTED = GAMMA_DELAY_CYCLES - GAMMA_OFFSET_LAT;

  logic [FP32_WIDTH-1:0] gamma_for_delay [NUM_LANES];

  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_gamma_offset
      if (MODEL_FAMILY == "GEMMA")
      begin : gen_gemma_offset
        logic dummy_valid;
        fp_add #(
                 .FP_WIDTH(FP32_WIDTH), .EXP_WIDTH(8), .MAN_WIDTH(23)
               ) u_gamma_add_one (
                 .clk(clk),
                 .rst_n(rst_n),
                 .a(gamma_raw[i]),
                 .b(32'h3F800000),   // 1.0 in FP32
                 .valid_in(1'b1),
                 .result(gamma_for_delay[i]),
                 .valid_out(dummy_valid),
                 .flags()
               );
      end
      else
      begin : gen_no_offset
        assign gamma_for_delay[i] = gamma_raw[i];
      end
    end
  endgenerate

  // Use explicit delay module instances (adjusted for Gemma fp_add latency)
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_gamma_delay
      delay #(.DLY(GAMMA_DELAY_ADJUSTED), .DW(FP32_WIDTH)) u_gamma_delay (
              .clk(clk), .rst_n(rst_n), .en(1'b1), .din(gamma_for_delay[i]), .dout(gamma_lane[i])
            );
    end
  endgenerate

  //===========================================================================
  // Mean Calculation: mean = total_sum / N
  //===========================================================================

  // Convert current_vector_len (N) to FP32
  // We do this once when entering ST_CALC_MEAN state
  logic        n_conv_start;
  logic        n_conv_valid;
  logic [31:0] n_int32;

  assign n_int32 = {16'b0, vector_len_reg};  // Zero extend to 32-bit
  assign n_conv_start = (state_out == S_OUT_CALC_MEAN && !div_mean_busy && !div_mean_valid);  // Start conversion when output stage is ready

  int_to_fp #(
              .INT_WIDTH(32),
              .FP_WIDTH(FP32_WIDTH),
              .EXP_WIDTH(8),
              .MAN_WIDTH(23)
            ) u_n_to_fp (
              .clk(clk),
              .rst_n(rst_n),
              .int_in({16'b0, vector_len_reg}),
              .valid_in(n_conv_start),
              .fp_out(n_fp32),
              .valid_out(n_conv_valid),
              .flags()
            );

  // Divide total_sum by N
  // Start division when N conversion is complete and we are in CALC_MEAN state
  logic div_mean_start;
  assign div_mean_start = (state_out == S_OUT_CALC_MEAN) && !div_mean_busy && n_conv_valid;

  fp_div #(
           .FP_WIDTH(FP32_WIDTH),
           .EXP_WIDTH(8),
           .MAN_WIDTH(23)
         ) u_div_mean (
           .clk(clk),
           .rst_n(rst_n),
           .a(total_sum_reg),
           .b(n_fp32),
           .valid_in(div_mean_start),
           .result(div_mean_result),
           .valid_out(div_mean_valid),
           .busy(div_mean_busy),
           .flags()
         );


  // Add epsilon to mean
  // mean_plus_eps = mean + epsilon
  logic        eps_add_valid_in;
  logic        eps_add_valid_out;
  logic [31:0] eps_add_result;

  assign eps_add_valid_in = div_mean_valid;

  fp_add #(
           .FP_WIDTH(FP32_WIDTH),
           .EXP_WIDTH(8),
           .MAN_WIDTH(23)
         ) u_add_eps (
           .clk(clk),
           .rst_n(rst_n),
           .a(div_mean_result),
           .b(cfg_epsilon),
           .valid_in(eps_add_valid_in),
           .result(eps_add_result),
           .valid_out(eps_add_valid_out),
           .flags()
         );

  //===========================================================================
  // Fast Inverse Square Root: inv_rms = 1 / sqrt(mean + eps)
  // Uses Quake's fast inverse sqrt with 2 Newton-Raphson iterations
  // Latency: 45 cycles if num_iter is 2 or 23 cycles if num_iter is 1 (vs 58 cycles for fp_sqrt + fp_div)
  //===========================================================================

  quake_fastinverse #(
                      .FP_WIDTH(FP32_WIDTH),
                      .EXP_WIDTH(8),
                      .MAN_WIDTH(23),
                      .NUM_ITERATIONS(1), //23 cycles if num_iter is 1 or 45 cycles if u assign 2 here
                      .USE_DSP(USE_DSP),
                      .DEBUG(DEBUG)
                    ) u_fast_inv_sqrt (
                      .clk(clk),
                      .rst_n(rst_n),
                      .a(eps_add_result),
                      .valid_in(eps_add_valid_out),
                      .result(fast_inv_sqrt_result),
                      .valid_out(fast_inv_sqrt_valid),
                      .flags()
                    );

  // Latch inv_rms (final normalization factor)
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      inv_rms <= 0;
      inv_rms_valid <= 1'b0;
    end
    else if (fast_inv_sqrt_valid)
    begin
      inv_rms <= fast_inv_sqrt_result;
      inv_rms_valid <= 1'b1;
    end
    else if (state_out == S_OUT_IDLE)
    begin
      inv_rms_valid <= 1'b0;
    end
  end

  //===========================================================================
  // Output Normalization Pipeline (8 parallel lanes)
  //===========================================================================
  // Flow is replay_data_raw (Int32) → FP32 → *inv_rms → *gamma → Int8
  //
  // BRAM read has 1cc latency
  // fifo_re -> (1 cycle) -> replay_data_raw valid
  // So valid_in to int_to_fp must be delayed by 1 cycle to match.

  // Delay fifo_re by 1 cycle to align with BRAM output
  logic fifo_re_d1;
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
      fifo_re_d1 <= 1'b0;
    else
      fifo_re_d1 <= fifo_re;
  end

  // Reconvert Int32 to FP32
  logic [FP32_WIDTH-1:0] replay_fp32 [NUM_LANES];
  logic [NUM_LANES-1:0]  replay_fp32_valid;

  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_replay_conv
      int_to_fp #(
                  .INT_WIDTH(INPUT_BITS),
                  .FP_WIDTH(FP32_WIDTH),
                  .EXP_WIDTH(8),
                  .MAN_WIDTH(23)
                ) u_replay_to_fp (
                  .clk(clk),
                  .rst_n(rst_n),
                  .int_in(replay_data_raw[i]),
                  .valid_in(fifo_re_d1),  // delayed valid to match BRAM latency
                  .fp_out(replay_fp32[i]),
                  .valid_out(replay_fp32_valid[i]),
                  .flags()
                );
    end
  endgenerate

  // Pipeline register for replay_fp32 (fixes timing)
  logic [FP32_WIDTH-1:0] replay_fp32_reg [NUM_LANES];
  logic [NUM_LANES-1:0]  replay_fp32_valid_reg;

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        replay_fp32_reg[i] <= 0;
      end
      replay_fp32_valid_reg <= 0;
    end
    else
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        replay_fp32_reg[i] <= replay_fp32[i];
      end
      replay_fp32_valid_reg <= replay_fp32_valid;
    end
  end

  // Multiply by inv_rms (x * inv_rms = x / rms)
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_norm_mul
      fp_mul #(
               .FP_WIDTH(FP32_WIDTH),
               .EXP_WIDTH(8),
               .MAN_WIDTH(23),
               .USE_DSP(USE_DSP)
             ) u_norm_mul (
               .clk(clk),
               .rst_n(rst_n),
               .a(replay_fp32_reg[i]),
               .b(inv_rms),
               .valid_in(replay_fp32_valid_reg[i]),
               .result(norm_lane[i]),
               .valid_out(norm_valid[i]),
               .flags()
             );
    end
  endgenerate

  // Multiply by gamma weight
  generate
    for (genvar i = 0; i < NUM_LANES; i++)
    begin : gen_gamma_mul
      fp_mul #(
               .FP_WIDTH(FP32_WIDTH),
               .EXP_WIDTH(8),
               .MAN_WIDTH(23),
               .USE_DSP(USE_DSP)
             ) u_gamma_mul (
               .clk(clk),
               .rst_n(rst_n),
               .a(norm_lane[i]),
               .b(gamma_lane[i]),
               .valid_in(norm_valid[i]),
               .result(gamma_scaled[i]),
               .valid_out(gamma_valid[i]),
               .flags()
             );
    end
  endgenerate

  // Pipeline register for gamma_scaled
  logic [FP32_WIDTH-1:0] gamma_scaled_reg [NUM_LANES];
  logic [NUM_LANES-1:0]  gamma_valid_reg;

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        gamma_scaled_reg[i] <= 0;
      end
      gamma_valid_reg <= 0;
    end
    else
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        gamma_scaled_reg[i] <= gamma_scaled[i];
      end
      gamma_valid_reg <= gamma_valid;
    end
  end

  // Convert FP32 to output precision (INT8 or BF16)
  generate
    if (PRECISION == "BF16")
    begin : gen_bf16_output
      // Add extra pipeline register to match INT8 path latency (fp_to_int + saturation = 2 cycles)
      for (genvar i = 0; i < NUM_LANES; i++)
      begin : gen_bf16_lane
        logic [15:0] bf16_result;
        logic        bf16_valid;
        logic        bf16_inexact;  // Unused but available for debug

        cast_fp32_to_bf16 #(
                            .ROUNDING(1)  // Round to nearest even
                          ) u_fp32_to_bf16 (
                            .clk(clk),
                            .rst_n(rst_n),
                            .fp32_in(gamma_scaled_reg[i]),
                            .valid_in(gamma_valid_reg[i]),
                            .bf16_out(bf16_result),
                            .valid_out(bf16_valid),
                            .inexact(bf16_inexact)
                          );

        // Extra pipeline register to match INT8 path latency
        always_ff @(posedge clk or negedge rst_n)
        begin
          if (!rst_n)
          begin
            output_quant[i] <= 16'h0;
            quant_valid[i] <= 1'b0;
          end
          else
          begin
            output_quant[i] <= bf16_result;
            quant_valid[i] <= bf16_valid;
          end
        end
      end
    end
    else
    begin : gen_int8_output
      // INT8: FP32 -> Int32 -> saturate to Int8
      for (genvar i = 0; i < NUM_LANES; i++)
      begin : gen_int8_lane
        logic [31:0] int32_result;
        logic        int32_valid;

        fp_to_int #(
                    .FP_WIDTH(FP32_WIDTH),
                    .INT_WIDTH(32),
                    .EXP_WIDTH(8),
                    .MAN_WIDTH(23)
                  ) u_fp_to_int (
                    .clk(clk),
                    .rst_n(rst_n),
                    .fp_in(gamma_scaled_reg[i]),
                    .valid_in(gamma_valid_reg[i]),
                    .int_out(int32_result),
                    .valid_out(int32_valid),
                    .flags()
                  );

        // Saturate Int32 to Int8 range [-128, 127]
        always_ff @(posedge clk or negedge rst_n)
        begin
          if (!rst_n)
          begin
            output_quant[i] <= 8'd0;
            quant_valid[i] <= 1'b0;
          end
          else if (int32_valid)
          begin
            if ($signed(int32_result) > 127)
              output_quant[i] <= 8'sd127;
            else if ($signed(int32_result) < -128)
              output_quant[i] <= -8'sd128;
            else
              output_quant[i] <= int32_result[7:0];
            quant_valid[i] <= 1'b1;
          end
          else
          begin
            quant_valid[i] <= 1'b0;
          end
        end
      end
    end
  endgenerate

  //===========================================================================
  // Output Packer
  // Accumulate PACK_BEATS of 8 lanes = OUTPUT_PACK_SIZE values = 256 bits
  // INT8: 4 beats * 8 lanes = 32 * 8 bits = 256 bits
  // BF16: 2 beats * 8 lanes = 16 * 16 bits = 256 bits
  //===========================================================================

  logic [DATA_WIDTH-1:0] pack_data_comb;
  logic pack_valid_comb;

  always_comb
  begin
    pack_data_comb = {DATA_WIDTH{1'b0}};
    for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
    begin
      pack_data_comb[i*OUTPUT_BITS +: OUTPUT_BITS] = output_pack_buf[i];
    end

    // On final beat, use live output_quant values
    if (state_out == S_OUT_STREAM && quant_valid[0] && pack_beat_cnt == PACK_BEATS - 1)
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        pack_data_comb[((PACK_BEATS-1) * NUM_LANES + i)*OUTPUT_BITS +: OUTPUT_BITS] = output_quant[i];
      end
    end
  end

  assign pack_valid_comb = (state_out == S_OUT_STREAM) && quant_valid[0] && (pack_beat_cnt == PACK_BEATS - 1);

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      pack_beat_cnt <= 0;
      for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
      begin
        output_pack_buf[i] <= {OUTPUT_BITS{1'b0}};
      end
    end
    else if (state_out == S_OUT_STREAM && quant_valid[0])
    begin
      for (int i = 0; i < NUM_LANES; i++)
      begin
        output_pack_buf[pack_beat_cnt * NUM_LANES + i] <= output_quant[i];
      end

      if (pack_beat_cnt == PACK_BEATS - 1)
        pack_beat_cnt <= 0;
      else
        pack_beat_cnt <= pack_beat_cnt + 1;
    end
  end

  //===========================================================================
  // Element Counter
  //===========================================================================
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      element_count <= 0;
    end
    else if (state_in == S_IN_IDLE && start)
    begin
      element_count <= 0;
    end
    else if (s_axis_tvalid && s_axis_tready && state_in == S_IN_ACCUM)
    begin
      element_count <= element_count + NUM_LANES;
    end
  end

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      output_count <= 0;
    end
    else if (state_out == S_OUT_CALC_INV && fast_inv_sqrt_valid)
    begin
      output_count <= 0;
    end
    else if (pack_valid_comb && fifo_ready)
    begin
      output_count <= output_count + OUTPUT_PACK_SIZE;  // OUTPUT_PACK_SIZE values per packed beat
    end
  end

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      gamma_rd_addr <= 0;
    end
    else if (state_out == S_OUT_CALC_INV && fast_inv_sqrt_valid)
    begin
      gamma_rd_addr <= 0;
    end
    else if (fifo_re)
    begin
      gamma_rd_addr <= gamma_rd_addr + NUM_LANES;
    end
  end

  //===========================================================================
  // DUAL FSM Implementation
  //===========================================================================

  // Input FSM (Accumulator)
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
      state_in <= S_IN_IDLE;
    else
      state_in <= state_in_next;
  end

  always_comb
  begin
    state_in_next = state_in;

    case (state_in)
      S_IN_IDLE:
      begin
        if (start || s_axis_tvalid)
          state_in_next = S_IN_ACCUM;
      end

      S_IN_ACCUM:
      begin
        if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
          state_in_next = S_IN_DRAIN;
      end

      S_IN_DRAIN:
      begin
        if (pipeline_done)
          state_in_next = S_IN_REDUCE_INIT;
      end

      S_IN_REDUCE_INIT:
      begin
        if (reduce_init_cnt == FP_ADD_LATENCY)
          state_in_next = S_IN_REDUCE;
      end

      S_IN_REDUCE:
      begin
        if (reduce_done)
        begin
          // Wait for space in handoff FIFO
          if (!handoff_full)
            state_in_next = S_IN_ACCUM;
        end
      end

      default:
        state_in_next = S_IN_IDLE;
    endcase
  end

  // Output FSM (Normalizer)
  // Consumes from Handoff FIFO, does mean/inv, then streams.

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
      state_out <= S_OUT_IDLE;
    else
      state_out <= state_out_next;
  end

  always_comb
  begin
    state_out_next = state_out;
    case (state_out)
      S_OUT_IDLE:
      begin
        if (!handoff_empty)
          state_out_next = S_OUT_WAIT_CMD;
      end

      S_OUT_WAIT_CMD:
      begin
        // One cycle delay to allow FIFO output to stabilize/register if needed
        // and to transition into calculation safely using current_total_sum
        state_out_next = S_OUT_CALC_MEAN;
      end

      S_OUT_CALC_MEAN:
      begin
        if (div_mean_valid)
          state_out_next = S_OUT_CALC_INV;
      end

      S_OUT_CALC_INV:
      begin
        if (fast_inv_sqrt_valid)
          state_out_next = S_OUT_STREAM;
      end

      S_OUT_STREAM:
      begin
        if (output_count >= vector_len_reg)
          state_out_next = S_OUT_DONE;
      end

      S_OUT_DONE:
      begin
        // Stay in DONE until output FIFO is empty (all data drained)
        if (output_fifo_empty)
          state_out_next = S_OUT_IDLE;
      end

      default:
        state_out_next = S_OUT_IDLE;
    endcase
  end

  //===========================================================================
  // Output FIFO handles pipeline skid during backpressure
  //===========================================================================

  logic pack_last_to_fifo;
  logic fifo_ready;

  // Pack data for FIFO input
  always_comb
  begin
    pack_last_to_fifo = (output_count >= vector_len_reg - OUTPUT_PACK_SIZE);
  end

  // Output FIFO instance
  // FIFO output signals
  logic fifo_tvalid;
  logic fifo_tlast;
  logic [DATA_WIDTH-1:0] fifo_tdata;

  // Output FIFO instance
  axis_fifo_banked #(
                     .DATA_WIDTH(DATA_WIDTH),
                     .DEPTH(2*FIFO_DEPTH_POW2)  // Power of 2, >= CREDIT_DEPTH
                   ) u_output_fifo (
                     .clk(clk),
                     .rst_n(rst_n),
                     // From packer
                     .s_axis_tdata(pack_data_comb),
                     .s_axis_tvalid(pack_valid_comb),
                     .s_axis_tready(fifo_ready),  // depth is sufficient
                     .s_axis_tlast(pack_last_to_fifo),
                     // To external
                     .m_axis_tdata(fifo_tdata),
                     .m_axis_tvalid(fifo_tvalid),
                     .m_axis_tready(m_axis_tready),
                     .m_axis_tlast(fifo_tlast),
                     // Status
                     .fifo_empty(output_fifo_empty),
                     .fifo_full()
                   );
  logic output_fifo_empty;

  assign m_axis_tvalid = fifo_tvalid;
  assign m_axis_tdata  = fifo_tdata;
  assign m_axis_tlast  = fifo_tlast && fifo_tvalid;

  // Ready when we are in accumulator state and have space in handoff FIFO
  assign s_axis_tready = (state_in == S_IN_ACCUM) && !handoff_full;

  assign busy = (state_in != S_IN_IDLE) || (state_out != S_OUT_IDLE) || !handoff_empty;
  // Wait for output FIFO to drain before asserting done
  assign done = (state_out == S_OUT_DONE) && output_fifo_empty;

  assign credit_available = (credit_counter >= OUTPUTS_PER_INPUT);

  // Consume credit event
  assign credit_consume = fifo_re && (credit_beat_cnt == (INPUTS_PER_OUTPUT - 1));
  assign credit_return = m_axis_tvalid && m_axis_tready;  // Return when output consumed

  // Count input beats
  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      credit_beat_cnt <= 0;
    end
    else if (state_out == S_OUT_IDLE)
    begin
      credit_beat_cnt <= 0;
    end
    else if (fifo_re)
    begin
      if (credit_beat_cnt == INPUTS_PER_OUTPUT - 1)
        credit_beat_cnt <= 0;
      else
        credit_beat_cnt <= credit_beat_cnt + 1;
    end
  end

  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      credit_counter <= CREDIT_DEPTH;
    end
    else if (state_out == S_OUT_IDLE) // Reset on output idle
    begin
      credit_counter <= CREDIT_DEPTH;
      // Reset credits at start of new operation
    end
    else
    begin
      case ({credit_consume, credit_return})
        2'b10:
          credit_counter <= credit_counter - OUTPUTS_PER_INPUT;  // Consumed credits
        2'b01:
          credit_counter <= credit_counter + 1;                  // Returned a credit
        2'b11:
          if (OUTPUTS_PER_INPUT > 1)
            credit_counter <= credit_counter - OUTPUTS_PER_INPUT + 1; // Net change
          else
            credit_counter <= credit_counter; // Net zero if ratio is 1
        default:
          credit_counter <= credit_counter;
      endcase
    end
  end


  always_ff @(posedge clk or negedge rst_n)
  begin
    if (!rst_n)
    begin
      tlast_pipe <= 0;
    end
    else
    begin
      // Shift tlast through pipeline
      tlast_pipe <= {tlast_pipe[PIPE_DEPTH-2:0],
                     (s_axis_tvalid && s_axis_tready && s_axis_tlast && state_in == S_IN_ACCUM)};
    end
  end

  assign pipeline_done = tlast_pipe[PIPE_DEPTH-1];

`include "rms_norm_debugmonitor.svh"
  //we moved this here since monitor was very long and distractive
endmodule
