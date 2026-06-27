`timescale 1ns / 1ps

///////////////////////////////////////////////////////////////////////////////
// RMSNorm Testbench - Multi-Dimension Testing
//
// Description:
//   Comprehensive testbench for RMSNorm accelerator.
//   Tests multiple vector sizes
//
// Configuration Guide:
//   For input shape (batch=1, dim=N) Set MAX_VECTOR_SIZE >= N (hardware limit)
//
// Engineer     : Yusuf SUR
///////////////////////////////////////////////////////////////////////////////

module rms_norm_tb;

  //===========================================================================
  // Parameters
  //===========================================================================
  localparam CLK_PERIOD       = 2.6;    // 370 MHz is max of design
  localparam NUM_LANES        = 16;
  localparam DATA_WIDTH       = 512;
  localparam USE_DSP          = 1;
  localparam INPUT_PRECISION  = "INT32"; // "INT32" or "INT8" input
  localparam PRECISION        = "BF16";  // "INT8" or "BF16" output
  localparam WARNING_BF16_REL_ERR_HIGH = 0;  // BF16 HAS REL_ERR because python uses truncate and our bf16 uses round to nearest if u want to see it set it to 1 but our loose comparison has tolerance
  localparam DEBUG            = 0;
  localparam DEBUG_CYCLES     = 0;
  localparam DEBUG_FIFO_DEPTH = 0;

  // Derived parameters for input
  localparam INPUT_BITS = (INPUT_PRECISION == "INT8") ? 8 : 32;
  localparam INPUT_PACK_SIZE = DATA_WIDTH / INPUT_BITS;  // 8 for INT32, 32 for INT8

  // Derived parameters for output
  localparam OUTPUT_BITS = (PRECISION == "BF16") ? 16 : 8;
  localparam OUTPUT_PACK_SIZE = DATA_WIDTH / OUTPUT_BITS;  // 32 for INT8, 16 for BF16

  // MAX_VECTOR_SIZE determines the hardware capacity
  localparam MAX_VECTOR_SIZE  = 12288;

  // Test dimensions - must be divisible by OUTPUT_PACK_SIZE
  localparam int TEST_DIMS[9] = '{64, 1152, 2048, 3072, 4096, 5120, 6144, 8192, 12288};
  localparam int NUM_TESTS = 9;

  //===========================================================================
  // Clock and Reset
  //===========================================================================
  logic clk;
  logic rst_n;

  initial
  begin
    clk = 0;
    forever
      #(CLK_PERIOD/2) clk = ~clk;
  end

  //===========================================================================
  // DUT Signals
  //===========================================================================
  // AXI-Stream Slave
  logic [DATA_WIDTH-1:0] s_axis_tdata;
  logic                  s_axis_tvalid;
  logic                  s_axis_tready;
  logic                  s_axis_tlast;

  // AXI-Stream Master
  logic [DATA_WIDTH-1:0] m_axis_tdata;
  logic                  m_axis_tvalid;
  logic                  m_axis_tready;
  logic                  m_axis_tlast;

  // Control
  logic                  start;
  logic                  done;
  logic                  busy;

  // Configuration
  logic [31:0]           cfg_epsilon;

  // Gamma interface (Wide DMA - parallel write to all banks)
  logic                  gamma_we_wide;
  logic [15:0]           gamma_addr_wide;
  logic [DATA_WIDTH-1:0] gamma_wdata_wide;

  // Gamma busy signal (output from DUT - indicates gamma is being read)
  logic                  gamma_busy;

  //===========================================================================
  // DUT Instantiation
  //===========================================================================
  rms_norm #(
             .MAX_VECTOR_SIZE(MAX_VECTOR_SIZE),
             .NUM_LANES(NUM_LANES),
             .DEBUG(DEBUG),
             .DEBUG_CYCLES(DEBUG_CYCLES),
             .DEBUG_FIFO_DEPTH(DEBUG_FIFO_DEPTH),
             .USE_DSP(USE_DSP),
             .DATA_WIDTH(DATA_WIDTH),
             .INPUT_PRECISION(INPUT_PRECISION),
             .PRECISION(PRECISION)
           ) dut (
             .clk(clk),
             .rst_n(rst_n),
             .s_axis_tdata(s_axis_tdata),
             .s_axis_tvalid(s_axis_tvalid),
             .s_axis_tready(s_axis_tready),
             .s_axis_tlast(s_axis_tlast),
             .m_axis_tdata(m_axis_tdata),
             .m_axis_tvalid(m_axis_tvalid),
             .m_axis_tready(m_axis_tready),
             .m_axis_tlast(m_axis_tlast),
             .start(start),
             .done(done),
             .busy(busy),
             .cfg_epsilon(cfg_epsilon),

             // Wide gamma interface (DMA path for fast parallel writes)
             .gamma_we_wide(gamma_we_wide),
             .gamma_addr_wide(gamma_addr_wide),
             .gamma_wdata_wide(gamma_wdata_wide),
             .gamma_busy(gamma_busy)
           );

  //===========================================================================
  // Test Data - Dynamic sizing based on MAX_VECTOR_SIZE
  //===========================================================================
  logic signed [31:0] test_input [MAX_VECTOR_SIZE];
  real                reference_output [MAX_VECTOR_SIZE];
  logic [OUTPUT_BITS-1:0] actual_output [MAX_VECTOR_SIZE];  // INT8 or BF16
  real                gamma_ref [MAX_VECTOR_SIZE];

  // Current test dimension (set by run_test task)
  int current_dim;

  // Test counters
  int total_tests, total_pass, total_fail;
  int test_count, pass_count, fail_count;

  // Timing measurement
  longint start_cycle, end_cycle;
  longint cycle_count;

  //===========================================================================
  // Helper Functions
  //===========================================================================
  function automatic logic [31:0] real_to_fp32(input real val);
    return $shortrealtobits(shortreal'(val));
  endfunction

  function automatic real fp32_to_real(input logic [31:0] bits);
    return real'($bitstoshortreal(bits));
  endfunction

  function automatic string get_model_name(input int dim);
    case (dim)
      64:
        return "Small Test";
      1152:
        return "Custom / Mobile";
      2048:
        return "Gemma-2B";
      3072:
        return "Gemma-7B";
      4096:
        return "LLaMA-7B / LLaMA-2-7B / Mistral-7B";
      5120:
        return "LLaMA-13B / LLaMA-2-13B";
      6144:
        return "Falcon-40B";
      8192:
        return "LLaMA-3-70B / Mixtral 8x7B";
      12288:
        return "GPT-3 (175B)";
      default:
        return "Unknown";
    endcase
  endfunction

  //===========================================================================
  // Advanced Backpressure Testing Parameters
  //===========================================================================
  localparam int MAX_LATENCY            = 100;  // Max pipeline latency allowance
  localparam int GAP_BETWEEN_TESTS      = 50;   // Cycles between test phases
  localparam int MANY_CYCLES            = 200;  // Cycles for stress phases

  // Backpressure gap randomization function
  function automatic int randomize_gap();
    int gap_class;
    gap_class = $urandom_range(1, 100);

    if (gap_class <= 60)       // 60% probability: no gap
      return 0;
    else if (gap_class <= 95)  // 35% probability: gap 1..3
      return $urandom_range(1, 3);
    else                       // 5% probability: gap 4..10
      return $urandom_range(4, 10);
  endfunction

  // Convert BF16 to real for verification
  function automatic real bf16_to_real(logic [15:0] bf16);
    logic        sign;
    logic [7:0]  exponent;
    logic [6:0]  mantissa;
    real         result;
    int          exp_unbiased;

    sign     = bf16[15];
    exponent = bf16[14:7];
    mantissa = bf16[6:0];

    if (exponent == 8'hFF)
    begin
      // Infinity or NaN
      if (mantissa == 0)
        result = sign ? -1.0e38 : 1.0e38;  // Approximate infinity
      else
        result = 0.0;  // NaN as 0 for testing
    end
    else if (exponent == 8'h00)
    begin
      // Zero or denormal (treat as zero for simplicity)
      result = 0.0;
    end
    else
    begin
      // Normal number
      exp_unbiased = int'(exponent) - 127;
      result = (1.0 + real'(mantissa) / 128.0) * (2.0 ** exp_unbiased);
      if (sign)
        result = -result;
    end

    return result;
  endfunction

  //===========================================================================
  // Tasks
  //===========================================================================

  // Reset the DUT
  task automatic reset_dut();
    rst_n <= 0;
    start <= 0;
    s_axis_tvalid <= 0;
    s_axis_tdata <= '0;
    s_axis_tlast <= 0;
    m_axis_tready <= 1;

    gamma_we_wide <= 0;
    gamma_addr_wide <= '0;
    gamma_wdata_wide <= '0;
    cfg_epsilon <= real_to_fp32(1e-5);

    // Clear output arrays
    for (int i = 0; i < MAX_VECTOR_SIZE; i++)
    begin
      actual_output[i] = 8'sd0;
      test_input[i] = 0;
      reference_output[i] = 0.0;
      gamma_ref[i] = 1.0;
    end

    repeat(10) @(posedge clk);
    rst_n <= 1;
    repeat(5) @(posedge clk);
  endtask



  //===========================================================================
  // Initialize gamma weights using Wide DMA bus (fast parallel writes)
  // For 16-lane with 256-bit bus: 8 FP32 values per beat, 2 beats per row
  // For 8-lane with 256-bit bus: 8 FP32 values per beat, 1 beat per row
  //===========================================================================
  task automatic init_gamma_wide(input int dim);
    real gamma_val;
    int  rows;
    int  values_per_beat;
    int  beats_per_row;
    int  gamma_idx;

    // Calculate how many FP32 values fit in DATA_WIDTH
    values_per_beat = DATA_WIDTH / 32;  // 8 for 256-bit, 16 for 512-bit

    // Calculate beats per row based on NUM_LANES vs values_per_beat
    if (values_per_beat >= NUM_LANES)
      beats_per_row = 1;  // Can write all lanes in one beat
    else
      beats_per_row = NUM_LANES / values_per_beat;  // Need multiple beats

    rows = dim / NUM_LANES;

    $display(" \n[TB] Initializing %0d gamma weights via Wide DMA bus...", dim);
    $display("  [TB]   values_per_beat=%0d, beats_per_row=%0d, rows=%0d",
             values_per_beat, beats_per_row, rows);

    // First, populate gamma_ref array for verification
    for (int i = 0; i < dim; i++)
    begin
      case (i % 4)
        0:
          gamma_val = 0.5;
        1:
          gamma_val = 1.0;
        2:
          gamma_val = 1.5;
        3:
          gamma_val = 2.0;
      endcase
      gamma_ref[i] = gamma_val;
    end

    // Write using wide DMA interface
    gamma_idx = 0;

    for (int row = 0; row < rows; row++)
    begin
      for (int beat = 0; beat < beats_per_row; beat++)
      begin
        // Pack gamma values into wide data bus
        gamma_wdata_wide <= '0;
        for (int v = 0; v < values_per_beat; v++)
        begin
          gamma_wdata_wide[v*32 +: 32] <= real_to_fp32(gamma_ref[gamma_idx + v]);
        end

        // Set address based on addressing scheme
        // For 16-lane with 256-bit bus: addr[0] selects lower/upper half
        // addr = row * beats_per_row + beat
        gamma_addr_wide <= row * beats_per_row + beat;
        gamma_we_wide <= 1;

        @(posedge clk);

        gamma_idx = gamma_idx + values_per_beat;
      end
    end

    gamma_we_wide <= 0;
    gamma_addr_wide <= '0;
    gamma_wdata_wide <= '0;
    repeat(2) @(posedge clk);

    $display("  [TB] Wide DMA gamma write complete (%0d beats total)", rows * beats_per_row);
  endtask
  // Generate test input data for given dimension
  task automatic generate_test_data(input int dim);
    real sum_sq, rms, epsilon;

    sum_sq = 0.0;
    epsilon = 1e-5;

    for (int i = 0; i < dim; i++)
    begin
      // Generate pattern: values from -50 to 50 to stress dynamic range
      test_input[i] = (i % 101) - 50;
      sum_sq = sum_sq + real'(test_input[i]) * real'(test_input[i]);
    end

    // Calculate reference output
    rms = $sqrt(sum_sq / dim + epsilon);

    $display("  [TB] Sum of squares: %.2f, Mean: %.4f, RMS: %.6f, InvRMS: %.6f",
             sum_sq, sum_sq / dim, rms, 1.0 / rms);

    for (int i = 0; i < dim; i++)
    begin
      reference_output[i] = (real'(test_input[i]) / rms) * gamma_ref[i];
      // Clamp to Int8 range
      if (reference_output[i] > 127.0)
        reference_output[i] = 127.0;
      if (reference_output[i] < -128.0)
        reference_output[i] = -128.0;
    end
  endtask

  // Send test data via AXI-Stream
  task automatic send_data(input int dim);
    int beat_count;
    int elements_sent;

    beat_count = dim / NUM_LANES;  // RTL processes NUM_LANES per beat
    elements_sent = 0;

    start <= 1;
    @(posedge clk);
    start <= 0;

    // Wait for ready
    while (!s_axis_tready)
      @(posedge clk);

    for (int beat = 0; beat < beat_count; beat++)
    begin
      // Pack NUM_LANES values into data (may not use full 256-bit bus for INT8)
      for (int lane = 0; lane < NUM_LANES; lane++)
      begin
        s_axis_tdata[lane*INPUT_BITS +: INPUT_BITS] <= test_input[beat * NUM_LANES + lane];
      end

      s_axis_tvalid <= 1;
      s_axis_tlast <= (beat == beat_count - 1);

      @(posedge clk);
      while (!s_axis_tready)
        @(posedge clk);

      elements_sent = elements_sent + NUM_LANES;
    end

    s_axis_tvalid <= 0;
    s_axis_tlast <= 0;
  endtask

  // Send test data with random input gaps (advanced backpressure on sender side)
  task automatic send_data_with_gaps(input int dim, input bit random_gap = 1);
    int beat_count;
    int elements_sent;
    int gap;

    beat_count = dim / NUM_LANES;  // RTL processes NUM_LANES per beat
    elements_sent = 0;

    start <= 1;
    @(posedge clk);
    start <= 0;

    // Wait for ready
    while (!s_axis_tready)
      @(posedge clk);

    for (int beat = 0; beat < beat_count; beat++)
    begin
      // Pack NUM_LANES values into data
      for (int lane = 0; lane < NUM_LANES; lane++)
      begin
        s_axis_tdata[lane*INPUT_BITS +: INPUT_BITS] <= test_input[beat * NUM_LANES + lane];
      end

      s_axis_tvalid <= 1;
      s_axis_tlast <= (beat == beat_count - 1);

      @(posedge clk);
      while (!s_axis_tready)
        @(posedge clk);

      elements_sent = elements_sent + NUM_LANES;

      // Add random gap between beats
      s_axis_tvalid <= 0;
      if (random_gap)
        gap = randomize_gap();
      else
        gap = 0;

      repeat (gap) @(posedge clk);
    end

    s_axis_tvalid <= 0;
    s_axis_tlast <= 0;
  endtask

  // Receive output data with optional random backpressure
  task automatic receive_data(input int dim, input bit enable_backpressure = 0);
    int received;
    int timeout;
    int max_timeout;

    received = 0;
    timeout = 0;
    // Scale timeout - larger for backpressure mode
    max_timeout = enable_backpressure ? dim * 300 : dim * 100;
    m_axis_tready <= 1;

    while (received < dim && timeout < max_timeout)
    begin
      @(posedge clk);
      timeout++;

      // Handle backpressure - toggle ready based on random
      if (enable_backpressure)
      begin
        // 20% chance to deassert ready (but don't add extra cycle)
        m_axis_tready <= ($urandom_range(0, 9) >= 2);
      end

      if (m_axis_tvalid && m_axis_tready)
      begin
        // OUTPUT_PACK_SIZE values per beat (32 for INT8, 16 for BF16)
        for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
        begin
          if (received + i < dim)
          begin
            actual_output[received + i] = m_axis_tdata[i*OUTPUT_BITS +: OUTPUT_BITS];
          end
        end
        received = received + OUTPUT_PACK_SIZE;
      end
    end

    // Ensure ready is high at end
    m_axis_tready <= 1;

    if (timeout >= max_timeout)
    begin
      $display("  [TB] ERROR: Timeout waiting for output! (received %0d/%0d)", received, dim);
    end
  endtask

  // Verify results for given dimension
  task automatic verify_results(input int dim);
    int errors;
    real expected, actual_r, diff, tolerance, rel_err;

    errors = 0;
    test_count = dim;

    // Different tolerance for different precisions
    // INT8: +-2 due to quantization
    // BF16: +-0.1% relative error due to mantissa truncation
    tolerance = (PRECISION == "BF16") ? 0.0 : 2.0;

    for (int i = 0; i < dim; i++)
    begin
      expected = reference_output[i];

      if (PRECISION == "BF16")
        actual_r = bf16_to_real(actual_output[i]);
      else
        actual_r = real'($signed(actual_output[i]));

      diff = actual_r - expected;

      // For BF16: FAIL if rel_err > 1%, WARN if rel_err > 0.5%
      // For INT8: use absolute error (+-2)
      if (PRECISION == "BF16")
      begin
        rel_err = (expected != 0.0) ? ((diff < 0.0) ? -diff/expected : diff/expected) : ((diff < 0.0) ? -diff : diff);
        if (rel_err < 0.0)
          rel_err = -rel_err;  // Ensure positive

        if (rel_err > 0.01)
        begin  // > 1% is FAIL
          if (errors < 5)
            $display("  [FAIL] idx=%0d: expected %.4f, got %.4f (rel_err=%.2f%%)",
                     i, expected, actual_r, rel_err * 100.0);
          errors++;
        end
        else if (rel_err > 0.005)
        begin  // > 0.5% is WARN (but still PASS)
          if (errors < 3 && WARNING_BF16_REL_ERR_HIGH)  // Show fewer warnings
            $display("  [WARN] idx=%0d: rel_err high (%.2f%%) - expected %.4f, got %.4f",
                     i, rel_err * 100.0, expected, actual_r);
        end
      end
      else
      begin
        // INT8: absolute tolerance +-2
        if (diff > 2.0 || diff < -2.0)
        begin
          if (errors < 5)
          begin
            $display("  [FAIL] idx=%0d: expected %.2f, got %0d (diff=%.2f)",
                     i, expected, $signed(actual_output[i]), diff);
          end
          errors++;
        end
      end
    end

    pass_count = test_count - errors;
    fail_count = errors;

    // Update totals
    total_tests += test_count;
    total_pass += pass_count;
    total_fail += fail_count;
  endtask

  //===========================================================================
  // File-Based Test: Load from .mem files generated by Python script
  //===========================================================================
  // Storage for file-based test data
  logic signed [31:0] file_input [MAX_VECTOR_SIZE];        // For INT32 input files
  logic signed [7:0]  file_input_int8 [MAX_VECTOR_SIZE];   // For INT8 input files
  logic [31:0]        file_gamma [MAX_VECTOR_SIZE];
  logic [OUTPUT_BITS-1:0] file_expected [MAX_VECTOR_SIZE];  // INT8 or BF16

  task automatic run_test_from_files(
      input string input_file,
      input string gamma_file,
      input string expected_file,
      input int dim
    );
    int fd, code, idx;
    string line;
    int errors;
    real diff;
    real time_us;
    real rel_err;

    $display("\n=============================================================");
    $display("  File-Based Test: dim=%0d", dim);
    $display("  Input:    %s", input_file);
    $display("  Gamma:    %s", gamma_file);
    $display("  Expected: %s", expected_file);
    $display("=============================================================");

    // Check dimension
    if (dim > MAX_VECTOR_SIZE)
    begin
      $display("  [ERROR] dim=%0d exceeds MAX_VECTOR_SIZE=%0d", dim, MAX_VECTOR_SIZE);
      return;
    end

    //=========================================================================
    // Load input data from .mem file
    // INT8:  Uses 8-bit array (file has 2-hex-digit values)
    // INT32: Uses 32-bit array (file has 8-hex-digit values)
    //=========================================================================
    $display("  [TB] Loading input data (INPUT_PRECISION=%s)...", INPUT_PRECISION);
    if (INPUT_PRECISION == "INT8")
    begin
      $readmemh(input_file, file_input_int8);
    end
    else
    begin
      $readmemh(input_file, file_input);
    end

    //=========================================================================
    // Load gamma weights from .mem file
    //=========================================================================
    $display("  [TB] Loading gamma weights...");
    $readmemh(gamma_file, file_gamma);

    //=========================================================================
    // Load expected outputs from .mem file
    //=========================================================================
    $display("  [TB] Loading expected outputs...");
    $readmemh(expected_file, file_expected);

    //=========================================================================
    // Soft reset and configure DUT
    //=========================================================================
    rst_n <= 0;
    repeat(3) @(posedge clk);
    rst_n <= 1;
    repeat(3) @(posedge clk);

    cfg_epsilon <= real_to_fp32(1e-5);
    repeat(2) @(posedge clk);

    //=========================================================================
    // Load gamma weights from file using Wide DMA interface
    //=========================================================================
    $display("  [TB] Programming %0d gamma weights...", dim);
    begin
      int values_per_beat_gamma;
      int beats_needed_gamma;

      values_per_beat_gamma = DATA_WIDTH / 32;  // Each gamma is FP32
      beats_needed_gamma = (dim + values_per_beat_gamma - 1) / values_per_beat_gamma;

      for (int beat = 0; beat < beats_needed_gamma; beat++)
      begin
        logic [DATA_WIDTH-1:0] gamma_beat_wide = '0;

        // Pack multiple FP32 gamma values into wide beat
        for (int v = 0; v < values_per_beat_gamma; v++)
        begin
          int idx = beat * values_per_beat_gamma + v;
          if (idx < dim)
            gamma_beat_wide[v*32 +: 32] = file_gamma[idx];
        end

        gamma_we_wide <= 1;
        gamma_addr_wide <= beat;
        gamma_wdata_wide <= gamma_beat_wide;
        @(posedge clk);
      end
      gamma_we_wide <= 0;
      repeat(2) @(posedge clk);
    end


    //=========================================================================
    // Copy input data to test_input array for send_data task
    // For INT8: sign-extend 8-bit values to 32-bit
    //=========================================================================
    for (int i = 0; i < dim; i++)
    begin
      if (INPUT_PRECISION == "INT8")
      begin
        // Sign-extend INT8 to INT32
        test_input[i] = {{24{file_input_int8[i][7]}}, file_input_int8[i]};
      end
      else
      begin
        test_input[i] = file_input[i];
      end
    end

    //=========================================================================
    // Clear output arrays
    //=========================================================================
    for (int i = 0; i < dim; i++)
    begin
      actual_output[i] = {OUTPUT_BITS{1'b0}};
    end

    //=========================================================================
    // Run DUT
    //=========================================================================
    $display("  [TB] Running DUT...");
    start_cycle = $time / CLK_PERIOD;

    fork
      send_data(dim);
      receive_data(dim, 0);
    join

    while (!done)
      @(posedge clk);

    end_cycle = $time / CLK_PERIOD;
    cycle_count = end_cycle - start_cycle;

    //=========================================================================
    // Verify against expected output from file
    //=========================================================================
    $display("  [TB] Verifying against expected output...");
    errors = 0;
    test_count = dim;

    for (int i = 0; i < dim; i++)
    begin
      real actual_r, expected_r;

      if (PRECISION == "BF16")
      begin
        actual_r = bf16_to_real(actual_output[i]);
        expected_r = bf16_to_real(file_expected[i]);
        diff = actual_r - expected_r;

        // For BF16: FAIL if rel_err > 1%, WARN if rel_err > 0.5%
        rel_err = (expected_r != 0.0) ? ((diff < 0.0) ? -diff/expected_r : diff/expected_r) : ((diff < 0.0) ? -diff : diff);
        if (rel_err < 0.0)
          rel_err = -rel_err;  // Ensure positive

        if (rel_err > 0.01)
        begin  // > 1% is FAIL
          if (errors < 5)
            $display("  [FAIL] idx=%0d: expected %.4f, got %.4f (rel_err=%.2f%%)",
                     i, expected_r, actual_r, rel_err * 100.0);
          errors++;
        end
        else if (rel_err > 0.005)
        begin  // > 0.5% is WARN (but still PASS)
          if (errors < 3 &&WARNING_BF16_REL_ERR_HIGH)  // Show fewer warnings
            $display("  [WARN] idx=%0d: rel_err high (%.2f%%) - expected %.4f, got %.4f",
                     i, rel_err * 100.0, expected_r, actual_r);
        end
      end
      else
      begin
        // INT8 comparison
        diff = real'($signed(actual_output[i])) - real'($signed(file_expected[i]));
        if (diff > 2.0 || diff < -2.0)
        begin
          if (errors < 5)
          begin
            $display("  [FAIL] idx=%0d: expected %0d, got %0d (diff=%.2f)",
                     i, $signed(file_expected[i]), $signed(actual_output[i]), diff);
          end
          errors++;
        end
      end
    end

    pass_count = test_count - errors;
    fail_count = errors;
    total_tests += test_count;
    total_pass += pass_count;
    total_fail += fail_count;

    //=========================================================================
    // Report
    //=========================================================================
    $display("  [RESULT] %0d/%0d passed (%.1f%%) in %0d cycles",
             pass_count, test_count, 100.0 * pass_count / test_count, cycle_count);
    $display("  [PERF] Throughput: %.2f elements/cycle, %.2f cycles/element",
             real'(dim) / cycle_count, real'(cycle_count) / dim);
    $display("  [TIME] %.3f us @ %.0f MHz", real'(cycle_count) * CLK_PERIOD / 1000.0, 1000.0 / CLK_PERIOD);

    if (errors == 0)
      $display("  [PASS] File-based test PASSED!");
    else
      $display("  [FAIL] File-based test FAILED with %0d errors!", errors);

    repeat(20) @(posedge clk);
  endtask

  // Run a single test for specified dimension
  task automatic run_test(input int dim, input bit backpressure = 0);
    $display("\n=============================================================");
    $display("  Testing dim=%0d (%s)", dim, get_model_name(dim));
    $display("  Shape: (1, %0d) | Backpressure: %s", dim, backpressure ? "ON" : "OFF");
    $display("=============================================================");

    // Check dimension is valid
    if (dim > MAX_VECTOR_SIZE)
    begin
      $display("  [SKIP] dim=%0d exceeds MAX_VECTOR_SIZE=%0d", dim, MAX_VECTOR_SIZE);
      return;
    end

    if (dim % 32 != 0)
    begin
      $display("  [SKIP] dim=%0d not divisible by 32", dim);
      return;
    end

    // Clear output arrays before each test
    for (int i = 0; i < dim; i++)
    begin
      actual_output[i] = 8'sd0;
    end

    // Soft reset - pulse reset to clear DUT state
    rst_n <= 0;
    repeat(3) @(posedge clk);
    rst_n <= 1;
    repeat(3) @(posedge clk);

    // Configure
    current_dim = dim;
    cfg_epsilon <= real_to_fp32(1e-5);
    repeat(2) @(posedge clk);

    // Initialize gamma and test data
    init_gamma_wide(dim);
    generate_test_data(dim);

    // Start timing
    start_cycle = $time / CLK_PERIOD;

    // Run test
    fork
      send_data(dim);
      receive_data(dim, backpressure);
    join

    // Wait for done
    while (!done)
      @(posedge clk);

    // End timing
    end_cycle = $time / CLK_PERIOD;
    cycle_count = end_cycle - start_cycle;

    // Verify
    verify_results(dim);

    // Report
    $display("  [RESULT] %0d/%0d passed (%.1f%%) in %0d cycles",
             pass_count, test_count, 100.0 * pass_count / test_count, cycle_count);
    $display("  [PERF] Throughput: %.2f elements/cycle, %.2f cycles/element",
             real'(dim) / cycle_count, real'(cycle_count) / dim);
    $display("  [TIME] %.3f us @ %.0f MHz", real'(cycle_count) * CLK_PERIOD / 1000.0, 1000.0 / CLK_PERIOD);

    if (fail_count == 0)
      $display("  [PASS] dim=%0d test PASSED!", dim);
    else
      $display("  [FAIL] dim=%0d test FAILED with %0d errors!", dim, fail_count);

    // Wait before next test
    repeat(20) @(posedge clk);
  endtask

  //===========================================================================
  // Heavy Backpressure Test Task
  //===========================================================================
  task automatic run_test_heavy_backpressure(input int dim);
    $display("\n=============================================================");
    $display("  Heavy Backpressure Test: dim=%0d", dim);
    $display("  Receiver stalls 50%% of cycles to stress FIFO");
    $display("=============================================================");

    // Clear output arrays before test
    for (int i = 0; i < dim; i++)
    begin
      actual_output[i] = 8'sd0;
    end

    // Soft reset - pulse reset to clear DUT state
    rst_n <= 0;
    repeat(3) @(posedge clk);
    rst_n <= 1;
    repeat(3) @(posedge clk);

    // Configure
    current_dim = dim;
    cfg_epsilon <= real_to_fp32(1e-5);
    repeat(2) @(posedge clk);

    // Initialize gamma and test data
    init_gamma_wide(dim);
    generate_test_data(dim);

    // Start timing
    start_cycle = $time / CLK_PERIOD;

    // Run test with heavy receiver stalling
    fork
      send_data(dim);
      receive_data_heavy_bp(dim);
    join

    // Wait for done
    while (!done)
      @(posedge clk);

    // End timing
    end_cycle = $time / CLK_PERIOD;
    cycle_count = end_cycle - start_cycle;

    // Verify
    verify_results(dim);

    // Report
    $display("  [RESULT] %0d/%0d passed (%.1f%%) in %0d cycles",
             pass_count, test_count, 100.0 * pass_count / test_count, cycle_count);
    $display("  [TIME] %.3f us @ %.0f MHz", real'(cycle_count) * CLK_PERIOD / 1000.0, 1000.0 / CLK_PERIOD);

    if (fail_count == 0)
      $display("  [PASS] Heavy backpressure test PASSED!");
    else
      $display("  [FAIL] Heavy backpressure test FAILED with %0d errors!", fail_count);

    repeat(20) @(posedge clk);
  endtask

  //===========================================================================
  // Heavy Backpressure Receive Task (50% stall rate)
  //===========================================================================
  task automatic receive_data_heavy_bp(input int dim);
    int received;
    int timeout;
    int max_timeout;
    int stall_cycles;

    received = 0;
    timeout = 0;
    stall_cycles = 0;
    max_timeout = dim * 500;  // Much more time for heavy backpressure
    m_axis_tready <= 1;

    while (received < dim && timeout < max_timeout)
    begin
      @(posedge clk);
      timeout++;

      // 50% random backpressure - toggle ready
      if ($urandom_range(0, 1) == 0)
      begin
        m_axis_tready <= 0;
        stall_cycles++;
      end
      else
      begin
        m_axis_tready <= 1;
      end

      if (m_axis_tvalid && m_axis_tready)
      begin
        for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
        begin
          if (received + i < dim)
          begin
            actual_output[received + i] = m_axis_tdata[i*OUTPUT_BITS +: OUTPUT_BITS];
          end
        end
        received = received + OUTPUT_PACK_SIZE;
      end
    end

    // Ensure ready is high at end
    m_axis_tready <= 1;

    $display("  [TB] Heavy BP: received=%0d, stall_cycles=%0d (%.1f%%)",
             received, stall_cycles, 100.0 * stall_cycles / timeout);

    if (timeout >= max_timeout)
    begin
      $display("  [TB] ERROR: Timeout in heavy backpressure test!");
    end
  endtask

  //===========================================================================
  // Throughput Test Task: Blasts vectors back-to-back
  //===========================================================================
  task automatic run_throughput_test(input int dim, input int num_vectors);
    longint start_cyc, end_cyc, total_cyc;
    real throughput;

    $display("\n=============================================================");
    $display("  Throughput Test: dim=%0d, vectors=%0d", dim, num_vectors);
    $display("  Blasting vectors back-to-back to measure max throughput");
    $display("=============================================================");

    // Soft Reset
    rst_n <= 0;
    repeat(3) @(posedge clk);
    rst_n <= 1;
    repeat(3) @(posedge clk);

    // Configure
    current_dim = dim;
    cfg_epsilon <= real_to_fp32(1e-5);
    repeat(2) @(posedge clk);

    init_gamma_wide(dim);
    generate_test_data(dim); // Use same data for all vectors (simpler)

    // Mark start time
    start_cyc = $time / CLK_PERIOD;

    fork
      begin
        int beats_per_vector = dim / NUM_LANES;
        int total_beats = num_vectors * beats_per_vector;

        // Pulse Start ONCE to activate the pipeline
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Wait for ready
        while (!s_axis_tready)
          @(posedge clk);

        // Continuous Loop over ALL vectors beats
        for (int global_beat = 0; global_beat < total_beats; global_beat++)
        begin
          int beat_in_vector = global_beat % beats_per_vector;

          for (int lane = 0; lane < NUM_LANES; lane++)
            s_axis_tdata[lane*INPUT_BITS +: INPUT_BITS] <= test_input[beat_in_vector * NUM_LANES + lane];

          s_axis_tvalid <= 1;
          // Assert LAST on the final beat of EACH vector
          s_axis_tlast <= (beat_in_vector == beats_per_vector - 1);

          @(posedge clk);
          while (!s_axis_tready)
            @(posedge clk);
        end

        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;
      end

      // Thread 2: Receiver (Drains outputs to keep pipeline moving)
      begin
        for (int i = 0; i < num_vectors; i++)
        begin
          receive_data(dim, 0); // 0 = no backpressure
        end
      end
    join

    // Mark end time
    end_cyc = $time / CLK_PERIOD;
    total_cyc = end_cyc - start_cyc;

    // Calculate Stats
    throughput = real'(dim * num_vectors) / total_cyc;

    $display("  [PERF RESULT] Processed %0d vectors in %0d cycles start to finish (This indicates the data dropped in the pipeline and received from the output)", num_vectors, total_cyc);
    $display("  [PERF RESULT] Average Cycles/Vector: %.1f", real'(total_cyc)/num_vectors);
    $display("  [PERF RESULT] Throughput: %.2f elements/cycle", throughput);

    repeat(20) @(posedge clk);
  endtask
  //===========================================================================
  // Advanced Backpressure Test Task
  // Implements patterns from advanced_backpressure_tb.sv:
  //   1. Fill pipeline without backpressure
  //   2. Apply backpressure while continuing to send
  //   3. Drain pipeline
  //   4. Random input gaps + random output ready (fork/join stress)
  //===========================================================================
  task automatic run_advanced_backpressure_test(input int dim);
    int received;
    int timeout;
    int max_timeout;
    int errors;
    real diff;
    real rel_err;
    real time_us_adv;

    $display("\n=============================================================");
    $display("  Advanced Backpressure Test: dim=%0d", dim);
    $display("  Multi-phase stress test with complex BP patterns");
    $display("=============================================================");

    // Clear output arrays
    for (int i = 0; i < dim; i++)
    begin
      actual_output[i] = {OUTPUT_BITS{1'b0}};
    end

    // Soft reset
    rst_n <= 0;
    repeat(3) @(posedge clk);
    rst_n <= 1;
    repeat(3) @(posedge clk);

    // Configure
    current_dim = dim;
    cfg_epsilon <= real_to_fp32(1e-5);
    repeat(2) @(posedge clk);

    // Initialize gamma and test data
    init_gamma_wide(dim);
    generate_test_data(dim);

    $display("  [PHASE 1] Fill pipeline without backpressure");
    m_axis_tready <= 1;

    // Run test with combined sender gaps and receiver backpressure
    $display("  [PHASE 2] Send with random gaps + random receiver ready (fork/join)");

    fork
      // Timer: start when first input accepted
      begin
        @(posedge clk iff (s_axis_tvalid && s_axis_tready));
        start_cycle = $time / CLK_PERIOD;
      end
      // Sender: send MULTIPLE vectors to stress the double-buffering
      begin
        for(int k=0; k<20; k++)
        begin
          send_data_with_gaps(dim, (k%2)); // Alternating gaps/no-gaps
        end
      end

      // Receiver: random backpressure + HARD STALL
      begin
        int total_expected_beats = dim * 20; // 20 vectors
        received = 0;
        timeout = 0;
        max_timeout = dim * 500 * 20;

        // --- PHASE 2a: Random Backpressure ---
        // Consume about 10% of TOTAL data with random stalls
        while (received < total_expected_beats * 0.1 && timeout < max_timeout)
        begin
          @(posedge clk);
          timeout++;
          m_axis_tready <= ($urandom_range(0, 9) >= 3);

          if (m_axis_tvalid && m_axis_tready)
          begin
            for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
            begin
              if ((received + i) % dim < dim) // Simplified check
                actual_output[received + i] = m_axis_tdata[i*OUTPUT_BITS +: OUTPUT_BITS];
            end
            received = received + OUTPUT_PACK_SIZE;
          end
        end

        // --- PHASE 2b: HARD RECEIVER STALL ---
        // Stall while Sender is blasting remaining 18+ vectors!
        // This will force the Input FSM to fill both pages and then Block.
        $display("  [PHASE 2b] HARD STALL: Holding m_axis_tready=0 for 5000 cycles...");
        m_axis_tready <= 0;
        repeat(5000) @(posedge clk);
        $display("  [PHASE 2b] HARD STALL: Releasing stall.");

        // --- PHASE 2c: Resume Consumption ---
        while (received < total_expected_beats && timeout < max_timeout)
        begin
          @(posedge clk);
          timeout++;

          m_axis_tready <= ($urandom_range(0, 9) >= 2);

          if (m_axis_tvalid && m_axis_tready)
          begin
            for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
            begin
              // Just capture relative to current vector
              actual_output[received + i] = m_axis_tdata[i*OUTPUT_BITS +: OUTPUT_BITS];
            end
            received = received + OUTPUT_PACK_SIZE;
          end
        end
      end
    join

    $display("  [PHASE 3] Drain pipeline - ensure all data received");
    m_axis_tready <= 1;

    // Drain any remaining data
    timeout = 0;
    max_timeout = MAX_LATENCY + GAP_BETWEEN_TESTS;
    while (timeout < max_timeout)
    begin
      @(posedge clk);
      timeout++;

      if (m_axis_tvalid && m_axis_tready)
      begin
        for (int i = 0; i < OUTPUT_PACK_SIZE; i++)
        begin
          if (received + i < dim)
            actual_output[received + i] = m_axis_tdata[i*OUTPUT_BITS +: OUTPUT_BITS];
        end
        received = received + OUTPUT_PACK_SIZE;
      end
    end

    // Wait for done
    timeout = 0;
    while (!done && timeout < 1000)
    begin
      @(posedge clk);
      timeout++;
    end

    end_cycle = $time / CLK_PERIOD;
    cycle_count = end_cycle - start_cycle;

    // Verify results
    errors = 0;
    test_count = dim;

    for (int i = 0; i < dim; i++)
    begin
      real actual_r;

      // Convert output based on precision
      if (PRECISION == "BF16")
        actual_r = bf16_to_real(actual_output[i]);
      else
        actual_r = real'($signed(actual_output[i]));

      diff = actual_r - reference_output[i];

      // Tolerance: INT8 +-2, BF16 +-5% relative
      if (PRECISION == "BF16")
      begin
        rel_err = (reference_output[i] != 0.0) ? ((diff < 0.0) ? -diff/reference_output[i] : diff/reference_output[i]) : ((diff < 0.0) ? -diff : diff);
        if (rel_err < 0.0)
          rel_err = -rel_err;
        if (rel_err > 0.05)
        begin  // 5% tolerance for advanced BP test
          if (errors < 5)
            $display("  [FAIL] idx=%0d: expected %.2f, got %.2f (rel_err=%.1f%%)", i, reference_output[i], actual_r, rel_err * 100.0);
          errors++;
        end
      end
      else
      begin
        if (diff > 2.0 || diff < -2.0)
        begin
          if (errors < 5)
            $display("  [FAIL] idx=%0d: expected %.2f, got %0d", i, reference_output[i], $signed(actual_output[i]));
          errors++;
        end
      end
    end

    pass_count = test_count - errors;
    fail_count = errors;
    total_tests += test_count;
    total_pass += pass_count;
    total_fail += fail_count;

    // Report
    time_us_adv = real'(cycle_count) * CLK_PERIOD / 1000.0;  // ns to us

    $display("  [RESULT] %0d/%0d passed (%.1f%%) in %0d cycles",
             pass_count, test_count, 100.0 * pass_count / test_count, cycle_count);
    $display("  [TIME] %.3f us @ %.0f MHz", time_us_adv, 1000.0 / CLK_PERIOD);

    if (errors == 0)
      $display("  [PASS] Advanced backpressure test PASSED!");
    else
      $display("  [FAIL] Advanced backpressure test FAILED with %0d errors!", errors);

    repeat(GAP_BETWEEN_TESTS) @(posedge clk);
  endtask

  //===========================================================================
  // Test Wide DMA Gamma Path
  // Verifies that gamma weights can be written via the wide DMA bus interface
  // and produces correct RMSNorm output. This is the production path.
  //===========================================================================
  task automatic test_gamma_wide_dma(input int dim);
    int errors;
    real actual_r, diff, rel_err;
    real time_us;

    $display("\n=============================================================");
    $display("  Testing Wide DMA Gamma Path: dim=%0d", dim);
    $display("  NUM_LANES=%0d, DATA_WIDTH=%0d bits", NUM_LANES, DATA_WIDTH);
    $display("=============================================================");

    // Check dimension is valid
    if (dim > MAX_VECTOR_SIZE)
    begin
      $display("  [SKIP] dim=%0d exceeds MAX_VECTOR_SIZE=%0d", dim, MAX_VECTOR_SIZE);
      return;
    end

    if (dim % NUM_LANES != 0)
    begin
      $display("  [SKIP] dim=%0d not divisible by NUM_LANES=%0d", dim, NUM_LANES);
      return;
    end

    // Clear output arrays
    for (int i = 0; i < dim; i++)
    begin
      actual_output[i] = {OUTPUT_BITS{1'b0}};
    end

    // Soft reset
    rst_n <= 0;
    repeat(3) @(posedge clk);
    rst_n <= 1;
    repeat(3) @(posedge clk);

    // Configure
    current_dim = dim;
    cfg_epsilon <= real_to_fp32(1e-5);
    repeat(2) @(posedge clk);

    // Initialize gamma using Wide DMA path (this is what we're testing!)
    init_gamma_wide(dim);

    // Generate test data for reference calculation
    generate_test_data(dim);

    // Start timing
    start_cycle = $time / CLK_PERIOD;

    // Run DUT
    fork
      send_data(dim);
      receive_data(dim, 0);
    join

    // Wait for done
    while (!done)
      @(posedge clk);

    // End timing
    end_cycle = $time / CLK_PERIOD;
    cycle_count = end_cycle - start_cycle;

    // Verify results
    errors = 0;
    test_count = dim;

    for (int i = 0; i < dim; i++)
    begin
      if (PRECISION == "BF16")
        actual_r = bf16_to_real(actual_output[i]);
      else
        actual_r = real'($signed(actual_output[i]));

      diff = actual_r - reference_output[i];

      if (PRECISION == "BF16")
      begin
        rel_err = (reference_output[i] != 0.0) ?
                ((diff < 0.0) ? -diff/reference_output[i] : diff/reference_output[i]) :
                ((diff < 0.0) ? -diff : diff);
        if (rel_err < 0.0)
          rel_err = -rel_err;
        if (rel_err > 0.01)  // 1% tolerance
        begin
          if (errors < 5)
            $display("  [FAIL] idx=%0d: expected %.4f, got %.4f (rel_err=%.2f%%)",
                     i, reference_output[i], actual_r, rel_err * 100.0);
          errors++;
        end
      end
      else
      begin
        if (diff > 2.0 || diff < -2.0)
        begin
          if (errors < 5)
            $display("  [FAIL] idx=%0d: expected %.2f, got %0d (diff=%.2f)",
                     i, reference_output[i], $signed(actual_output[i]), diff);
          errors++;
        end
      end
    end

    pass_count = test_count - errors;
    fail_count = errors;
    total_tests += test_count;
    total_pass += pass_count;
    total_fail += fail_count;

    // Report
    time_us = real'(cycle_count) * CLK_PERIOD / 1000.0;

    $display("  [RESULT] %0d/%0d passed (%.1f%%) in %0d cycles",
             pass_count, test_count, 100.0 * pass_count / test_count, cycle_count);
    $display("  [TIME] %.3f us @ %.0f MHz", time_us, 1000.0 / CLK_PERIOD);

    if (errors == 0)
      $display("  [PASS] Wide DMA Gamma test PASSED!");
    else
      $display("  [FAIL] Wide DMA Gamma test FAILED with %0d errors!", errors);

    repeat(10) @(posedge clk);
  endtask

  //===========================================================================
  // Corner Case Tests for Wide DMA Gamma Path
  // Tests edge conditions that could cause issues in production:
  //   1. Minimal setup time after gamma write before start (all dimensions)
  //   2. Gamma busy gating test - writes during active computation should be blocked
  //===========================================================================
  task automatic test_gamma_wide_corner_cases();
    int errors;
    int total_corner_errors;
    real actual_r, diff, rel_err;
    int dim;
    int gamma_busy_seen;
    int write_attempts_during_busy;

    $display("\n=============================================================");
    $display("  CORNER CASE TESTS: Wide DMA Gamma Path");
    $display("=============================================================");

    total_corner_errors = 0;

    //-------------------------------------------------------------------------
    // Test 1: Minimal Setup Time (All Dimensions)
    // Write gamma, then start computation with only 1 cycle gap
    // This tests BRAM write-to-read timing across all dimensions
    //-------------------------------------------------------------------------
    $display("\n  [CORNER CASE 1] Minimal setup time test (all dimensions)");

    for (int t = 0; t < NUM_TESTS; t++)
    begin
      dim = TEST_DIMS[t];

      if (dim > MAX_VECTOR_SIZE)
        continue;

      // Reset
      rst_n <= 0;
      repeat(3) @(posedge clk);
      rst_n <= 1;
      repeat(3) @(posedge clk);

      cfg_epsilon <= real_to_fp32(1e-5);

      // Write gamma via wide DMA
      init_gamma_wide(dim);

      // MINIMAL GAP - only 1 cycle before starting computation!
      repeat(1) @(posedge clk);

      // Generate test data
      generate_test_data(dim);

      // Clear outputs
      for (int i = 0; i < dim; i++)
        actual_output[i] = {OUTPUT_BITS{1'b0}};

      // Run DUT
      fork
        send_data(dim);
        receive_data(dim, 0);
      join

      while (!done)
        @(posedge clk);

      // Verify
      errors = 0;
      for (int i = 0; i < dim; i++)
      begin
        if (PRECISION == "BF16")
          actual_r = bf16_to_real(actual_output[i]);
        else
          actual_r = real'($signed(actual_output[i]));
        diff = actual_r - reference_output[i];
        if (PRECISION == "BF16")
        begin
          rel_err = (reference_output[i] != 0.0) ?
                  ((diff < 0.0) ? -diff/reference_output[i] : diff/reference_output[i]) : 0.0;
          if (rel_err > 0.01)
            errors++;
        end
        else
        begin
          if (diff > 2.0 || diff < -2.0)
            errors++;
        end
      end

      if (errors == 0)
        $display("    [PASS] dim=%0d: Minimal setup time OK\n", dim);
      else
        $display("    [FAIL] dim=%0d: Minimal setup time FAILED with %0d errors\n", dim, errors);

      total_tests += dim;
      total_pass += (dim - errors);
      total_fail += errors;
      total_corner_errors += errors;
    end

    //-------------------------------------------------------------------------
    // Test 2: Gamma Busy Gating Test
    // Verify that gamma_busy signal properly blocks writes during computation
    // 1. Load gamma with known values
    // 2. Start computation (gamma_busy should go high)
    // 3. Attempt to write different gamma values while busy
    // 4. Verify original gamma values are still used (writes were blocked)
    //-------------------------------------------------------------------------
    $display("\n  [CORNER CASE 2] Gamma busy gating test (write protection)");

    for (int t = 0; t < 3; t++)  // Test first 3 dimensions for speed
    begin
      dim = TEST_DIMS[t];

      if (dim > MAX_VECTOR_SIZE)
        continue;

      // Reset
      rst_n <= 0;
      repeat(3) @(posedge clk);
      rst_n <= 1;
      repeat(3) @(posedge clk);

      cfg_epsilon <= real_to_fp32(1e-5);

      // Write CORRECT gamma via wide DMA (pattern: 0.5, 1.0, 1.5, 2.0)
      init_gamma_wide(dim);

      // Generate test data with CORRECT gamma reference
      generate_test_data(dim);

      // Clear outputs
      for (int i = 0; i < dim; i++)
        actual_output[i] = {OUTPUT_BITS{1'b0}};

      // Track gamma_busy behavior
      gamma_busy_seen = 0;
      write_attempts_during_busy = 0;

      // Start computation and attempt writes during gamma_busy
      fork
        // Thread 1: Send data
        send_data(dim);

        // Thread 2: Receive data
        receive_data(dim, 0);

        // Thread 3: Monitor gamma_busy and attempt illegal writes
        begin
          // Wait for gamma_busy to go high
          while (!gamma_busy && !done)
            @(posedge clk);

          if (gamma_busy)
          begin
            gamma_busy_seen = 1;
            $display(" [INFO] gamma_busy detected - attempting blocked writes");

            // Attempt to write WRONG gamma values (all zeros) while busy
            // These writes SHOULD be blocked by the gated write enables
            for (int attempt = 0; attempt < 10 && gamma_busy; attempt++)
            begin
              gamma_we_wide <= 1;
              gamma_addr_wide <= attempt;
              gamma_wdata_wide <= {DATA_WIDTH{1'b0}};  // Write zeros (WRONG values)
              write_attempts_during_busy++;
              @(posedge clk);
            end
            gamma_we_wide <= 0;
            gamma_addr_wide <= '0;
            gamma_wdata_wide <= '0;
          end
        end
      join

      while (!done)
        @(posedge clk);

      // Verify - if gating works, outputs should match reference (CORRECT gamma)
      // If gating failed, outputs would use wrong gamma (zeros) -> massive errors
      errors = 0;
      for (int i = 0; i < dim; i++)
      begin
        if (PRECISION == "BF16")
          actual_r = bf16_to_real(actual_output[i]);
        else
          actual_r = real'($signed(actual_output[i]));
        diff = actual_r - reference_output[i];
        if (PRECISION == "BF16")
        begin
          rel_err = (reference_output[i] != 0.0) ?
                  ((diff < 0.0) ? -diff/reference_output[i] : diff/reference_output[i]) : 0.0;
          if (rel_err > 0.01)
            errors++;
        end
        else
        begin
          if (diff > 2.0 || diff < -2.0)
            errors++;
        end
      end

      if (gamma_busy_seen)
      begin
        if (errors == 0)
          $display(" [PASS] dim=%0d: Gamma busy gating OK (%0d blocked writes, original gamma preserved)",
                   dim, write_attempts_during_busy);
        else
          $display(" [FAIL] dim=%0d: Gamma busy gating FAILED! (%0d errors - writes leaked through?)",
                   dim, errors);
      end
      else
      begin
        $display(" [WARN] dim=%0d: gamma_busy not observed (test may be too fast)", dim);
      end

      total_tests += dim;
      total_pass += (dim - errors);
      total_fail += errors;
      total_corner_errors += errors;
    end

    //-------------------------------------------------------------------------
    // Test 3: Continuous Gamma Streaming (all dimensions)
    // Write gamma values with zero gaps between beats (max throughput)
    //-------------------------------------------------------------------------
    $display("\n  [CORNER CASE 3] Continuous gamma streaming (all dimensions)");

    for (int t = 0; t < NUM_TESTS; t++)
    begin
      dim = TEST_DIMS[t];

      if (dim > MAX_VECTOR_SIZE)
        continue;

      // Reset
      rst_n <= 0;
      repeat(3) @(posedge clk);
      rst_n <= 1;
      repeat(3) @(posedge clk);

      cfg_epsilon <= real_to_fp32(1e-5);

      // Write gamma - init_gamma_wide already writes back-to-back
      init_gamma_wide(dim);

      repeat(2) @(posedge clk);

      generate_test_data(dim);

      // Clear outputs
      for (int i = 0; i < dim; i++)
        actual_output[i] = {OUTPUT_BITS{1'b0}};

      // Run DUT
      fork
        send_data(dim);
        receive_data(dim, 0);
      join

      while (!done)
        @(posedge clk);

      // Verify
      errors = 0;
      for (int i = 0; i < dim; i++)
      begin
        if (PRECISION == "BF16")
          actual_r = bf16_to_real(actual_output[i]);
        else
          actual_r = real'($signed(actual_output[i]));
        diff = actual_r - reference_output[i];
        if (PRECISION == "BF16")
        begin
          rel_err = (reference_output[i] != 0.0) ?
                  ((diff < 0.0) ? -diff/reference_output[i] : diff/reference_output[i]) : 0.0;
          if (rel_err > 0.01)
            errors++;
        end
        else
        begin
          if (diff > 2.0 || diff < -2.0)
            errors++;
        end
      end

      if (errors == 0)
        $display("    [PASS] dim=%0d: Continuous streaming OK", dim);
      else
        $display("    [FAIL] dim=%0d: Continuous streaming FAILED with %0d errors", dim, errors);

      total_tests += dim;
      total_pass += (dim - errors);
      total_fail += errors;
      total_corner_errors += errors;
    end

    $display("\n  [CORNER CASE SUMMARY] Total corner case errors: %0d", total_corner_errors);
    if (total_corner_errors == 0)
      $display("  [PASS] All corner case tests PASSED!");
    else
      $display("  [FAIL] Corner case tests had %0d total errors", total_corner_errors);

    repeat(10) @(posedge clk);
  endtask


  //===========================================================================
  // Main Test Sequence - Tests each dimension with and without backpressure
  //===========================================================================
  initial
  begin
    $display("\n");
    $display("###############################################################");
    $display("#  RMSNorm Accelerator - Multi-Dimension Testbench            #");
    $display("#  MAX_VECTOR_SIZE: %0d | NUM_LANES: %0d                       ", MAX_VECTOR_SIZE, NUM_LANES);
    $display("#  INPUT: %s | OUTPUT: %s                                      ", INPUT_PRECISION, PRECISION);
    $display("###############################################################");

    // Initialize counters
    total_tests = 0;
    total_pass = 0;
    total_fail = 0;

    // Reset
    reset_dut();

    //=========================================================================
    // Python Crosscheck: Verify HW against Python golden model
    //=========================================================================
    $display("\n");
    $display("###############################################################");
    $display("#  PYTHON CROSSCHECK: Verify against generated .mem files     #");
    $display("###############################################################");

    // Test all standard dimensions with their respective .mem files
    // Files are located in golden_mem folder
    // Input file differs based on INPUT_PRECISION:
    //   INT8:  input_data_int8_{dim}.mem
    //   INT32: input_data_{dim}.mem
    // Expected output file differs based on PRECISION:
    //   INT8: expected_output_{dim}.mem
    //   BF16: expected_output_bf16_{dim}.mem
    if (INPUT_PRECISION == "INT8")
    begin
      if (PRECISION == "BF16")
      begin
        run_test_from_files("input_data_int8_64.mem", "gamma_weights_64.mem", "expected_output_bf16_64.mem", 64);
        run_test_from_files("input_data_int8_1152.mem", "gamma_weights_1152.mem", "expected_output_bf16_1152.mem", 1152);
        run_test_from_files("input_data_int8_2048.mem", "gamma_weights_2048.mem", "expected_output_bf16_2048.mem", 2048);
        run_test_from_files("input_data_int8_3072.mem", "gamma_weights_3072.mem", "expected_output_bf16_3072.mem", 3072);
        run_test_from_files("input_data_int8_4096.mem", "gamma_weights_4096.mem", "expected_output_bf16_4096.mem", 4096);
        run_test_from_files("input_data_int8_5120.mem", "gamma_weights_5120.mem", "expected_output_bf16_5120.mem", 5120);
      end
      else
      begin
        run_test_from_files("input_data_int8_64.mem", "gamma_weights_64.mem", "expected_output_64.mem", 64);
        run_test_from_files("input_data_int8_1152.mem", "gamma_weights_1152.mem", "expected_output_1152.mem", 1152);
        run_test_from_files("input_data_int8_2048.mem", "gamma_weights_2048.mem", "expected_output_2048.mem", 2048);
        run_test_from_files("input_data_int8_3072.mem", "gamma_weights_3072.mem", "expected_output_3072.mem", 3072);
        run_test_from_files("input_data_int8_4096.mem", "gamma_weights_4096.mem", "expected_output_4096.mem", 4096);
        run_test_from_files("input_data_int8_5120.mem", "gamma_weights_5120.mem", "expected_output_5120.mem", 5120);
      end
    end
    else
    begin
      // INT32 input
      if (PRECISION == "BF16")
      begin
        run_test_from_files("input_data_64.mem", "gamma_weights_64.mem", "expected_output_bf16_64.mem", 64);
        run_test_from_files("input_data_1152.mem", "gamma_weights_1152.mem", "expected_output_bf16_1152.mem", 1152);
        run_test_from_files("input_data_2048.mem", "gamma_weights_2048.mem", "expected_output_bf16_2048.mem", 2048);
        run_test_from_files("input_data_3072.mem", "gamma_weights_3072.mem", "expected_output_bf16_3072.mem", 3072);
        run_test_from_files("input_data_4096.mem", "gamma_weights_4096.mem", "expected_output_bf16_4096.mem", 4096);
        run_test_from_files("input_data_5120.mem", "gamma_weights_5120.mem", "expected_output_bf16_5120.mem", 5120);
      end
      else
      begin
        run_test_from_files("input_data_64.mem", "gamma_weights_64.mem", "expected_output_64.mem", 64);
        run_test_from_files("input_data_1152.mem", "gamma_weights_1152.mem", "expected_output_1152.mem", 1152);
        run_test_from_files("input_data_2048.mem", "gamma_weights_2048.mem", "expected_output_2048.mem", 2048);
        run_test_from_files("input_data_3072.mem", "gamma_weights_3072.mem", "expected_output_3072.mem", 3072);
        run_test_from_files("input_data_4096.mem", "gamma_weights_4096.mem", "expected_output_4096.mem", 4096);
        run_test_from_files("input_data_5120.mem", "gamma_weights_5120.mem", "expected_output_5120.mem", 5120);
      end
    end

    $display("\n");
    $display("###############################################################");
    $display("#  PYTHON CROSSCHECK COMPLETE                                 #");
    $display("###############################################################");

    //=========================================================================
    // Wide DMA Gamma Test: Verify production gamma write path
    //=========================================================================
    $display("\n");
    $display("###############################################################");
    $display("#  WIDE DMA GAMMA TEST: Verify fast parallel gamma write path #");
    $display("###############################################################");

    // Run advanced backpressure on all dimensions
    for (int t = 0; t < NUM_TESTS; t++)
    begin
      test_gamma_wide_dma(TEST_DIMS[t]);
    end

    // Run corner case tests for gamma DMA
    test_gamma_wide_corner_cases();

    $display("\n");
    $display("###############################################################");
    $display("#  WIDE DMA GAMMA TEST COMPLETE                               #");
    $display("###############################################################");

    //=========================================================================
    // Phase 1: Normal Mode (No Backpressure)
    //=========================================================================
    $display("\n");
    $display("###############################################################");
    $display("#  PHASE 1: Normal Mode Tests (No Backpressure)               #");
    $display("###############################################################");

    for (int t = 0; t < NUM_TESTS; t++)
    begin
      run_test(TEST_DIMS[t], 0);  // Without backpressure
    end

    //=========================================================================
    // Phase 2: Backpressure Mode (Test FIFO)
    //=========================================================================
    $display("\n");
    $display("###############################################################");
    $display("#  PHASE 2: Backpressure Mode Tests (FIFO Stress)             #");
    $display("###############################################################");
    $display("#  Testing random receiver stalls to verify FIFO handles      #");
    $display("#  pipeline skid correctly.                                   #");
    $display("###############################################################");

    for (int t = 0; t < NUM_TESTS; t++)
    begin
      run_test(TEST_DIMS[t], 1);  // With backpressure
    end

    //=========================================================================
    // Phase 3: Advanced Backpressure Tests (Random Input Gaps + Random Output BP)
    //=========================================================================
    $display("\n");
    $display("###############################################################");
    $display("#  PHASE 3: Advanced Backpressure Tests                       #");
    $display("###############################################################");
    $display("#  Testing with random input gaps + random output stalls      #");
    $display("#  This is the most realistic stress test pattern.            #");
    $display("###############################################################");

    // Run advanced backpressure on all dimensions
    for (int t = 0; t < NUM_TESTS; t++)
    begin
      run_advanced_backpressure_test(TEST_DIMS[t]);
    end

    $display("\n");
    $display("###############################################################");
    $display("#  PHASE 4: Throughput Blast Test (10x Continuous)            #");
    $display("###############################################################");

    // Run advanced backpressure on all dimensions
    for (int t = 0; t < NUM_TESTS; t++)
    begin
      run_throughput_test(TEST_DIMS[t], 20); // 10 vectors back to back
    end

    //=========================================================================
    // Final Summary
    //=========================================================================
    $display("\n");
    $display("###############################################################");
    $display("#                    FINAL TEST SUMMARY                       #");
    $display("###############################################################");
    $display("#  Dimensions tested: %0d (x3 phases: normal + BP + advanced)", NUM_TESTS);
    $display("#  Total Elements:    %0d", total_tests);
    $display("#  Passed:            %0d", total_pass);
    $display("#  Failed:            %0d", total_fail);
    $display("#  Pass Rate:         %.2f%%", 100.0 * total_pass / total_tests);
    $display("###############################################################");

    if (total_fail == 0)
      $display("#  >>> ALL TESTS PASSED! <<<");
    else
      $display("#  >>> SOME TESTS FAILED! <<<");

    $display("###############################################################\n");

    repeat(50) @(posedge clk);
    $finish;
  end

  // Timeout watchdog - scale with max dimension
  initial
  begin
    #50000000;  // 50ms at 100MHz = 5M cycles
    $display("[TB] ERROR: Global timeout!");
    $finish;
  end
endmodule
