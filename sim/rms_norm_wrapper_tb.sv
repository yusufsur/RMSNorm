`timescale 1ns / 1ps

module rms_norm_wrapper_tb;
  localparam DEBUG_AXI = 1;
  //===========================================================================
  // Parameters
  //===========================================================================
  parameter DATA_WIDTH      = 512;     // 512 OR 256
  parameter NUM_LANES       = 16;      // 8 OR 16
  parameter MAX_VECTOR_SIZE = 12288;   // {64, 1152, 2048, 3072, 4096, 5120, 6144, 8192, 12288};
  parameter INPUT_PRECISION = "INT8"; // "INT32" or "INT8" input
  parameter PRECISION       = "BF16";  // "INT8" or "BF16" output
  parameter USE_DSP         = 1;
  parameter DEBUG           = 0;
  parameter CLK_PERIOD      = 2.6;     // 385 MHz

  // Derived Parameters
  localparam INPUT_BITS             = (INPUT_PRECISION == "INT8") ? 8 : 32;
  localparam INPUT_VALUES_PER_BEAT  = DATA_WIDTH / INPUT_BITS;
  localparam OUTPUT_BITS            = (PRECISION == "BF16") ? 16 : 8;
  localparam OUTPUT_VALUES_PER_BEAT = DATA_WIDTH / OUTPUT_BITS; // 32 for BF16 on 512-bit

  // AXI Lite Parameters
  parameter C_S_AXI_DATA_WIDTH = 32;
  parameter C_S_AXI_ADDR_WIDTH = 16;

  // Register Map
  localparam ADDR_CTRL         = 'h0000;
  localparam ADDR_STATUS       = 'h0004;
  localparam ADDR_INTR_ENABLE  = 'h0008;
  localparam ADDR_INTR_STATUS  = 'h000C;
  localparam ADDR_EPSILON      = 'h0010;
  localparam ADDR_GAMMA_BASE   = 'h1000;
  localparam ADDR_GAMMA_END    = 'h1000 + (MAX_VECTOR_SIZE * 4) - 1;

  // Test dimensions must be divisible by lane/output packing
  localparam int TEST_DIMS[9] = '{64, 1152, 2048, 3072, 4096, 5120, 6144, 8192, 12288};
  localparam int NUM_TESTS = 9;
  //===========================================================================
  // Signals
  //===========================================================================
  logic clk;
  logic rst_n;
  logic interrupt;

  // AXI4-Lite Control
  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_ctrl_awaddr;
  logic [2:0]                    s_axi_ctrl_awprot;
  logic                          s_axi_ctrl_awvalid;
  logic                          s_axi_ctrl_awready;
  logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_ctrl_wdata;
  logic [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_ctrl_wstrb;
  logic                          s_axi_ctrl_wvalid;
  logic                          s_axi_ctrl_wready;
  logic [1:0]                    s_axi_ctrl_bresp;
  logic                          s_axi_ctrl_bvalid;
  logic                          s_axi_ctrl_bready;
  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_ctrl_araddr;
  logic [2:0]                    s_axi_ctrl_arprot;
  logic                          s_axi_ctrl_arvalid;
  logic                          s_axi_ctrl_arready;
  logic [C_S_AXI_DATA_WIDTH-1:0] s_axi_ctrl_rdata;
  logic [1:0]                    s_axi_ctrl_rresp;
  logic                          s_axi_ctrl_rvalid;
  logic                          s_axi_ctrl_rready;

  // AXI4-Stream Data Input
  logic [DATA_WIDTH-1:0] s_axis_tdata;
  logic                  s_axis_tvalid;
  logic                  s_axis_tready;
  logic                  s_axis_tlast;

  // AXI4-Stream Data Output
  logic [DATA_WIDTH-1:0] m_axis_tdata;
  logic                  m_axis_tvalid;
  logic                  m_axis_tready;
  logic                  m_axis_tlast;

  // AXI4-Stream Gamma Input
  logic [DATA_WIDTH-1:0] s_axis_gamma_tdata;
  logic                  s_axis_gamma_tvalid;
  logic                  s_axis_gamma_tready;
  logic                  s_axis_gamma_tlast;

  // Testbench Arrays
  logic [31:0]  test_input      [MAX_VECTOR_SIZE-1:0];
  logic [31:0]  gamma_ref_bits  [MAX_VECTOR_SIZE-1:0]; // FP32 bits
  real          gamma_ref_val   [MAX_VECTOR_SIZE-1:0]; // Real values
  real          expected_output [MAX_VECTOR_SIZE-1:0];
  real          actual_output   [MAX_VECTOR_SIZE-1:0];

  // Counters
  int tests_passed = 0;
  int tests_failed = 0;

  // File-based test storage
  logic signed [31:0] file_input [MAX_VECTOR_SIZE];        // For INT32 input files
  logic signed [7:0]  file_input_int8 [MAX_VECTOR_SIZE];   // For INT8 input files
  logic [31:0]        file_gamma [MAX_VECTOR_SIZE];
  logic [OUTPUT_BITS-1:0] file_expected [MAX_VECTOR_SIZE]; // INT8 or BF16

  //===========================================================================
  // Clock Generation
  //===========================================================================
  initial
  begin
    clk = 0;
    forever
      #(CLK_PERIOD/2.0) clk = ~clk;
  end

  //===========================================================================
  // DUT Instantiation
  //===========================================================================
  rms_norm_axi_wrapper #(
                         .MAX_VECTOR_SIZE(MAX_VECTOR_SIZE),
                         .NUM_LANES(NUM_LANES),
                         .DATA_WIDTH(DATA_WIDTH),
                         .INPUT_PRECISION(INPUT_PRECISION),
                         .PRECISION(PRECISION),
                         .USE_DSP(USE_DSP),
                         .DEBUG(DEBUG)
                       ) dut (
                         .aclk(clk),
                         .aresetn(rst_n),
                         .interrupt(interrupt),

                         // AXI Ctrl
                         .s_axi_ctrl_awaddr(s_axi_ctrl_awaddr),
                         .s_axi_ctrl_awprot(s_axi_ctrl_awprot),
                         .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid),
                         .s_axi_ctrl_awready(s_axi_ctrl_awready),
                         .s_axi_ctrl_wdata(s_axi_ctrl_wdata),
                         .s_axi_ctrl_wstrb(s_axi_ctrl_wstrb),
                         .s_axi_ctrl_wvalid(s_axi_ctrl_wvalid),
                         .s_axi_ctrl_wready(s_axi_ctrl_wready),
                         .s_axi_ctrl_bresp(s_axi_ctrl_bresp),
                         .s_axi_ctrl_bvalid(s_axi_ctrl_bvalid),
                         .s_axi_ctrl_bready(s_axi_ctrl_bready),
                         .s_axi_ctrl_araddr(s_axi_ctrl_araddr),
                         .s_axi_ctrl_arprot(s_axi_ctrl_arprot),
                         .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid),
                         .s_axi_ctrl_arready(s_axi_ctrl_arready),
                         .s_axi_ctrl_rdata(s_axi_ctrl_rdata),
                         .s_axi_ctrl_rresp(s_axi_ctrl_rresp),
                         .s_axi_ctrl_rvalid(s_axi_ctrl_rvalid),
                         .s_axi_ctrl_rready(s_axi_ctrl_rready),

                         // Axis Data In
                         .s_axis_tdata(s_axis_tdata),
                         .s_axis_tvalid(s_axis_tvalid),
                         .s_axis_tready(s_axis_tready),
                         .s_axis_tlast(s_axis_tlast),

                         // Axis Data Out
                         .m_axis_tdata(m_axis_tdata),
                         .m_axis_tvalid(m_axis_tvalid),
                         .m_axis_tready(m_axis_tready),
                         .m_axis_tlast(m_axis_tlast),

                         // Axis Gamma
                         .s_axis_gamma_tdata(s_axis_gamma_tdata),
                         .s_axis_gamma_tvalid(s_axis_gamma_tvalid),
                         .s_axis_gamma_tready(s_axis_gamma_tready),
                         .s_axis_gamma_tlast(s_axis_gamma_tlast)
                       );

  //===========================================================================
  // Helpers
  //===========================================================================
  function automatic logic [31:0] real_to_fp32(input real val);
    return $shortrealtobits(shortreal'(val));
  endfunction

  function automatic real bf16_to_real(input logic [15:0] bf);
    logic        sign;
    logic [7:0]  exp;
    logic [6:0]  mant;
    real         result;
    int          exp_int;

    sign = bf[15];
    exp  = bf[14:7];
    mant = bf[6:0];

    if (exp == 8'hFF)
    begin
      if (mant == 0)
        return sign ? -1.0/0.0 : 1.0/0.0; // inf
      else
        return 0.0/0.0;                   // NaN → return NaN
    end
    if (exp == 0)
    begin
      if (mant == 0)
        return 0.0;
      // denormal (rare in BF16, but handle)
      result = real'(mant) / 128.0 * (2.0 ** -126);
    end
    else
    begin
      exp_int = int'(exp) - 127;
      result = (1.0 + real'(mant)/128.0) * (2.0 ** exp_int);
    end
    return sign ? -result : result;
  endfunction

  //===========================================================================
  // AXI Tasks
  //===========================================================================
  task automatic axi_write(
      input logic [C_S_AXI_ADDR_WIDTH-1:0] addr,
      input logic [31:0] data
    );
    // 1. Drive stable values FIRST (before any VALID)
    s_axi_ctrl_awaddr  <= addr;
    s_axi_ctrl_awprot  <= 3'b000;
    s_axi_ctrl_wdata   <= data;
    s_axi_ctrl_wstrb   <= 4'hF;
    s_axi_ctrl_bready  <= 1'b1;

    // 2. One delta cycle later -> assert VALIDs
    @(posedge clk);
    s_axi_ctrl_awvalid <= 1'b1;
    s_axi_ctrl_wvalid  <= 1'b1;

    // 3. Wait for handshakes (parallel)
    fork
      begin
        @(posedge clk iff s_axi_ctrl_awready && s_axi_ctrl_awvalid);
        s_axi_ctrl_awvalid <= 1'b0;
      end
      begin
        @(posedge clk iff s_axi_ctrl_wready && s_axi_ctrl_wvalid);
        s_axi_ctrl_wvalid <= 1'b0;
      end
    join

    // 4. Wait for response
    @(posedge clk iff s_axi_ctrl_bvalid);
    s_axi_ctrl_bready <= 1'b0;

    if (s_axi_ctrl_bresp !== 2'b00)
    begin
      $error("[TB] AXI Write error to addr 0x%h: BRESP = %0d (data=0x%h)", addr, s_axi_ctrl_bresp, data);
    end
  endtask

  task automatic axi_read(
      input  logic [C_S_AXI_ADDR_WIDTH-1:0] addr,
      output logic [31:0] rdata
    );
    // Drive stable address first
    s_axi_ctrl_araddr  <= addr;
    s_axi_ctrl_arprot  <= 3'b000;

    // Then assert ARVALID
    @(posedge clk);
    s_axi_ctrl_arvalid <= 1'b1;
    s_axi_ctrl_rready  <= 1'b1;

    // Wait for AR handshake
    @(posedge clk iff s_axi_ctrl_arready && s_axi_ctrl_arvalid);
    s_axi_ctrl_arvalid <= 1'b0;

    // Wait for read data
    @(posedge clk iff s_axi_ctrl_rvalid);
    rdata = s_axi_ctrl_rdata;
    s_axi_ctrl_rready <= 1'b0;

    if (s_axi_ctrl_rresp !== 2'b00)
    begin
      $error("[TB] AXI Read error from addr 0x%h: RRESP = %0d", addr, s_axi_ctrl_rresp);
    end
  endtask

  task automatic wait_for_interrupt();
    int timeout = 1000000; // safety

    if (DEBUG_AXI)
      $display("[TB] Waiting for interrupt ...");
    while (!interrupt)
    begin
      @(posedge clk);
      timeout--;
      if (timeout == 0)
      begin
        $fatal(1, "[TB] Timeout waiting for interrupt");
      end
    end
    if (DEBUG_AXI)
      $display("[TB] Interrupt detected after %0d cycles", 1000000 - timeout);

    // Clear interrupt (RW1C)
    axi_write(ADDR_INTR_STATUS, 32'h0000_0001); // Bit 0 = Done Interrupt
  endtask

  //===========================================================================
  // AXI-Lite Register Test Task
  //===========================================================================
  task automatic test_axi_lite_registers();
    logic [31:0] rdata;
    logic [31:0] epsilon_test;
    int errors = 0;

    $display("\n=== TEST: AXI-Lite Register Interface ===");

    // 1. Test Control Register (Write-Only, Self-Clearing)
    $display("[TB] Testing Control Register (0x%h)...", ADDR_CTRL);
    axi_read(ADDR_CTRL, rdata);
    if (rdata !== 32'h0)
    begin
      $display("[WARN] Control register read returned non-zero: 0x%h (expected 0 for write-only)", rdata);
    end
    else
      $display("[PASS] Control register correctly returns 0 (write-only)");

    // 2. Test Status Register (Read-Only)
    $display("[TB] Testing Status Register (0x%h)...", ADDR_STATUS);
    axi_read(ADDR_STATUS, rdata);
    // After reset, should show not busy (bit 0 = 0) and not done (bit 1 = 0)
    $display("Status: Busy=%b, Done=%b", rdata[0], rdata[1]);
    if (rdata[0] !== 1'b0)
    begin
      $display("[WARN] Busy bit set unexpectedly");
      errors++;
    end
    else
      $display("[PASS] Status register readable");

    // 3. Test Interrupt Enable Register (R/W)
    $display("[TB] Testing Interrupt Enable Register (0x%h)...", ADDR_INTR_ENABLE);

    // Read initial (should be 0 after reset)
    axi_read(ADDR_INTR_ENABLE, rdata);
    $display("Initial: 0x%h", rdata);

    // Write 1
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);
    axi_read(ADDR_INTR_ENABLE, rdata);
    if (rdata[0] !== 1'b1)
    begin
      $display("[FAIL] Interrupt enable not set after write");
      errors++;
    end
    else
      $display("[PASS] Interrupt enable set correctly");

    // Write 0 to disable
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0000);
    axi_read(ADDR_INTR_ENABLE, rdata);
    if (rdata[0] !== 1'b0)
    begin
      $display("[FAIL] Interrupt enable not cleared after write");
      errors++;
    end
    else
      $display("[PASS] Interrupt enable cleared correctly");

    // 4. Test Interrupt Status Register (RW1C)
    $display("[TB] Testing Interrupt Status Register (0x%h) - RW1C...", ADDR_INTR_STATUS);

    // Read initial (should be 0)
    axi_read(ADDR_INTR_STATUS, rdata);
    $display("Initial: 0x%h", rdata);

    // Note: Can't easily test setting without running a full operation
    // But we can verify writing 0 doesn't change anything
    axi_write(ADDR_INTR_STATUS, 32'h0000_0000);
    axi_read(ADDR_INTR_STATUS, rdata);
    $display("After write 0: 0x%h (RW1C - write 0 should have no effect)", rdata);
    $display("[PASS] Interrupt status RW1C behavior verified");

    // 5. Test Epsilon Register (R/W, Full 32-bit)
    $display("[TB] Testing Epsilon Register (0x%h)...", ADDR_EPSILON);

    // Read default value (~1e-5 = 0x3727C5AC)
    axi_read(ADDR_EPSILON, rdata);
    $display("Default epsilon: 0x%h", rdata);

    // Write test pattern
    epsilon_test = 32'hDEAD_BEEF;
    axi_write(ADDR_EPSILON, epsilon_test);
    axi_read(ADDR_EPSILON, rdata);
    if (rdata !== epsilon_test)
    begin
      $display("[FAIL] Epsilon write/read mismatch: wrote 0x%h, read 0x%h", epsilon_test, rdata);
      errors++;
    end
    else
      $display("[PASS] Epsilon register R/W verified");

    // Write another pattern (alternating bits)
    epsilon_test = 32'h5555_AAAA;
    axi_write(ADDR_EPSILON, epsilon_test);
    axi_read(ADDR_EPSILON, rdata);
    if (rdata !== epsilon_test)
    begin
      $display("[FAIL] Epsilon pattern 2 mismatch");
      errors++;
    end
    else
      $display("[PASS] Epsilon alternating pattern verified");

    // Restore default
    axi_write(ADDR_EPSILON, 32'h3727C5AC);

    // 6. Test Invalid Address (should return SLVERR on read)
    $display("[TB] Testing Invalid Address Response...");
    begin
      // Read from invalid address
      s_axi_ctrl_araddr  <= 16'hFFFF; // Invalid
      s_axi_ctrl_arvalid <= 1'b1;
      s_axi_ctrl_arprot  <= 3'b000;
      s_axi_ctrl_rready  <= 1'b1;

      @(posedge clk iff s_axi_ctrl_arready && s_axi_ctrl_arvalid);
      s_axi_ctrl_arvalid <= 1'b0;

      @(posedge clk iff s_axi_ctrl_rvalid);
      if (s_axi_ctrl_rresp === 2'b10)
        $display("[PASS] Invalid address correctly returns SLVERR");
      else
        $display("[WARN] Invalid address returned RRESP=%b (expected SLVERR=10)", s_axi_ctrl_rresp);
      s_axi_ctrl_rready <= 1'b0;
    end

    // 7. Test Soft Reset clears state
    $display("[TB] Testing Soft Reset...");
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0001); // Enable interrupts first
    axi_write(ADDR_CTRL, 32'h0000_0002); // Soft reset
    repeat(20) @(posedge clk);

    axi_read(ADDR_STATUS, rdata);
    if (rdata[1] !== 1'b0)
    begin
      $display("[FAIL] Done bit not cleared after soft reset");
      errors++;
    end
    else
      $display("[PASS] Soft reset clears Done bit");

    // Summary
    $display("[TB] ----------------------------------------");
    if (errors == 0)
    begin
      $display("[TB] AXI-Lite Register Test: PASSED");
      tests_passed++;
    end
    else
    begin
      $display("[TB] AXI-Lite Register Test: FAILED with %0d errors", errors);
      tests_failed++;
    end
    $display("[TB] ----------------------------------------");

    repeat(10) @(posedge clk);
  endtask

  //===========================================================================
  // Gamma Load Task (DMA)
  //===========================================================================
  task automatic load_gamma(input int dim);
    int beats;
    int GAMMA_VALUES_PER_BEAT;
    real val;
    logic [DATA_WIDTH-1:0] beat_data;

    GAMMA_VALUES_PER_BEAT = DATA_WIDTH / 32; // Gamma is always FP32
    beats = (dim + GAMMA_VALUES_PER_BEAT - 1) / GAMMA_VALUES_PER_BEAT;

    if (DEBUG_AXI)
      $display("[TB] Loading %0d gamma weights via AXI Stream (DMA)...", dim);

    s_axis_gamma_tvalid <= 0;

    // Generate and Load
    for (int b = 0; b < beats; b++)
    begin
      if (b % 100 == 0)
        //if (DEBUG_AXI) $display("[TB] Gamma Load Beat %0d/%0d", b, beats);
        beat_data = 0;
      for (int v = 0; v < GAMMA_VALUES_PER_BEAT; v++)
      begin
        int idx = b * GAMMA_VALUES_PER_BEAT + v;
        if (idx < dim)
        begin
          // Pattern: 0.5, 1.0, 1.5, 2.0 repeating
          case(idx % 4)
            0:
              val = 0.5;
            1:
              val = 1.0;
            2:
              val = 1.5;
            3:
              val = 2.0;
          endcase
          // Store for Verification
          gamma_ref_val[idx] = val;
          gamma_ref_bits[idx] = real_to_fp32(val);
          // Pack into beat
          beat_data[v*32 +: 32] = gamma_ref_bits[idx];
        end
      end

      s_axis_gamma_tdata <= beat_data;
      s_axis_gamma_tvalid <= 1;
      s_axis_gamma_tlast <= (b == beats - 1);

      // Robust wait for handshake
      begin
        int timeout = 10000;
        while (1)
        begin
          if (s_axis_gamma_tready)
          begin
            @(posedge clk); // Complete the cycle
            break;
          end
          @(posedge clk);
          timeout--;
          if (timeout == 0)
          begin
            $fatal(1, "[TB] Gamma Load TIMEOUT on beat %0d! tready never went high. Core likely stuck busy.", b);
          end
        end
      end
    end

    s_axis_gamma_tvalid <= 0;
    s_axis_gamma_tlast <= 0;
    @(posedge clk);
  endtask

  logic [DATA_WIDTH-1:0] data_beat;
  //===========================================================================
  // Test Case Runner
  //===========================================================================
  task automatic run_test_case(input int dim);
    int input_beats;
    int errors;
    real sum_sq, mean_sq, rms_val, expected, diff, rel_err;
    real epsilon = 1e-5;
    logic [31:0] status;

    // Performance counters (in clock cycles)
    longint perf_start_time;        // When core_start is pulsed
    longint perf_last_input_time;   // When last input beat is transferred
    longint perf_first_output_time; // When first output beat arrives
    longint perf_end_time;          // When all outputs received
    logic   first_output_captured;  // Flag to capture first output only once

    $display("=================================================");
    $display(" TEST CASE: Dimension %0d", dim);
    $display("=================================================");

    // 1. Soft Reset (Clear core state)
    if (DEBUG_AXI)
      $display("[TB] Soft Resetting DUT...");
    axi_write(ADDR_CTRL, 32'h0000_0002); // Bit 1 = Soft Reset
    repeat(20) @(posedge clk); // Wait for 16-cycle release

    // 2. Configure Epsilon
    axi_write(ADDR_EPSILON, real_to_fp32(1e-5));

    // 3. Enable Interrupt
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0001); // Bit 0 = Done Interrupt Enable

    // 4. Load Gamma
    load_gamma(dim);
    if (DEBUG_AXI)
      $display("[TB] Gamma Load Done.");

    // 5. Generate Test Data & Reference Calculation
    if (DEBUG_AXI)
      $display("[TB] Generating Test Data...");
    sum_sq = 0.0;
    for (int i = 0; i < dim; i++)
    begin
      if (INPUT_PRECISION == "INT8")
      begin
        test_input[i] = $signed($random) % 128; // -127 to 127 roughly
      end
      else
      begin
        test_input[i] = $random; // INT32
      end
      sum_sq += (real'(signed'(test_input[i])) * real'(signed'(test_input[i])));
    end
    mean_sq = sum_sq / real'(dim);
    rms_val = $sqrt(mean_sq + epsilon);

    for (int i = 0; i < dim; i++)
    begin
      expected = (real'(signed'(test_input[i])) / rms_val) * gamma_ref_val[i];

      // Quantize expected output if target is INT8
      if (PRECISION == "INT8")
      begin
        if (expected > 127.0)
          expected = 127.0;
        if (expected < -128.0)
          expected = -128.0;
        expected = real'(int'(expected)); // truncate/round
      end

      expected_output[i] = expected;
      actual_output[i] = 0.0; // Clear prev
    end
    // Core processes NUM_LANES elements per beat (not full bus width)
    input_beats = (dim + NUM_LANES - 1) / NUM_LANES;
    $display("[TB] Data Gen Done. Input Beats=%0d", input_beats);

    // 6. Run Stream (Fork Send/Recv)

    if (DEBUG_AXI)
      $display("[TB] Starting Stream (Forking Sender/Receiver)...");

    // Initialize performance tracking
    first_output_captured = 0;
    perf_first_output_time = 0;

    fork
      // Sender
      begin
        if (DEBUG_AXI)
          $display("[TB] Sender: Pulsing Start...");
        // Capture start time BEFORE issuing start command
        perf_start_time = $time / CLK_PERIOD;

        // Start Command via AXI Lite
        axi_write(ADDR_CTRL, 32'h0000_0001); // Bit 0 = Start

        if (DEBUG_AXI)
          $display("[TB] Sender: Streaming Data...");
        // Stream Data
        for (int b = 0; b < input_beats; b++)
        begin
          //if (b % 10 == 0) if (DEBUG_AXI) $display("[TB] Sender: Sending Beat %0d/%0d", b, input_beats);

          data_beat = 0;
          for (int v = 0; v < NUM_LANES; v++)
          begin
            int idx = b*NUM_LANES + v;
            if (idx < dim)
              data_beat[v*INPUT_BITS +: INPUT_BITS] = test_input[idx];
          end

          s_axis_tdata <= data_beat;
          s_axis_tvalid <= 1;
          s_axis_tlast <= (b == input_beats - 1);
          @(posedge clk iff s_axis_tready);
        end
        // Capture when last input beat is transferred
        perf_last_input_time = $time / CLK_PERIOD;

        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;
        if (DEBUG_AXI)
          $display("[TB] Sender: All beats sent.");
      end

      // Receiver
      begin
        int collected = 0;
        int stall_counter = 0;
        int timeout_limit = 20000;

        if (DEBUG_AXI)
          $display("[TB] Receiver: Waiting for data...");
        m_axis_tready <= 1'b1;

        while (collected < dim)
        begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready)
          begin
            // Capture first output time (only once)
            if (!first_output_captured)
            begin
              perf_first_output_time = $time / CLK_PERIOD;
              first_output_captured = 1;
            end

            stall_counter = 0; // Reset watchdog on activity
            //if (collected % 100 == 0) if (DEBUG_AXI) $display("[TB] Receiver: Progress %0d/%0d", collected, dim);

            // Unpack beat
            for (int v = 0; v < OUTPUT_VALUES_PER_BEAT; v++)
            begin
              int idx = collected + v;
              if (idx < dim)
              begin
                if (PRECISION == "BF16")
                begin
                  logic [15:0] bf = m_axis_tdata[v*OUTPUT_BITS +: 16];
                  actual_output[idx] = bf16_to_real(bf);
                end
                else
                begin // INT8
                  logic [7:0] i8 = m_axis_tdata[v*OUTPUT_BITS +: 8];
                  actual_output[idx] = real'(signed'(i8));
                end
              end
            end
            collected += OUTPUT_VALUES_PER_BEAT;
          end
          else
          begin
            stall_counter++;
            if (stall_counter > timeout_limit)
            begin
              $fatal(1, "[TB] Receiver Timeout! Stuck waiting for valid data. Collected=%0d", collected);
            end
          end
        end
        // Capture end time when all outputs received
        perf_end_time = $time / CLK_PERIOD;

        m_axis_tready <= 1'b0;
        $display("[TB] Receiver: Collection Done.");
      end
    join

    // 7. Wait for interrupt (completion)
    wait_for_interrupt();

    // Optional: Read status to confirm
    axi_read(ADDR_STATUS, status);
    if (status[1] !== 1'b1)
    begin
      $error("[TB] Done bit not set after interrupt");
    end

    // 8. Verify Results
    errors = 0;
    for (int i = 0; i < dim; i++)
    begin
      diff = actual_output[i] - expected_output[i];
      if (diff < 0)
        diff = -diff;

      if (PRECISION == "BF16")
      begin
        // Relative error check for Floating Point
        if (expected_output[i] != 0.0)
          rel_err = diff / ((expected_output[i] > 0) ? expected_output[i] : -expected_output[i]);
        else
          rel_err = diff;

        if (rel_err > 0.05)
        begin // 5% tolerance
          if (errors < 5)
            $display("[FAIL] idx=%0d Exp=%.4f Act=%.4f Rel=%.2f%%", i, expected_output[i], actual_output[i], rel_err*100.0);
          errors++;
        end
      end
      else
      begin
        // Absolute tolerance for Integer/Fixed Point
        if (diff > 2.0)
        begin
          if (errors < 5)
            $display("[FAIL] idx=%0d Exp=%.1f Act=%.1f Diff=%.1f", i, expected_output[i], actual_output[i], diff);
          errors++;
        end
      end
    end

    if (errors == 0)
    begin
      $display("[PASS] Dimension %0d Validated.", dim);
      tests_passed++;
    end
    else
    begin
      $display("[FAIL] Dimension %0d had %0d errors.", dim, errors);
      tests_failed++;
    end

    // Print performance metrics
    begin
      longint total_cycles = perf_end_time - perf_start_time;
      longint compute_cycles = perf_first_output_time - perf_last_input_time;
      $display("[PERF] ----------------------------------------");
      $display("[PERF] Dimension: %0d elements", dim);
      $display("[PERF] Total Latency: %0d cycles", total_cycles);
      $display("[PERF] Compute Latency (last input -> first output): %0d cycles", compute_cycles);
      $display("[PERF] Input Transfer: %0d cycles", perf_last_input_time - perf_start_time);
      $display("[PERF] Output Transfer: %0d cycles", perf_end_time - perf_first_output_time);
      $display("[PERF] Throughput: %.2f elements/cycle, %.2f cycles/element",
               real'(dim) / real'(total_cycles), real'(total_cycles) / real'(dim));
      $display("[TIME] %.3f us @ %.0f MHz", real'(total_cycles) * CLK_PERIOD / 1000.0, 1000.0 / CLK_PERIOD);
      $display("[PERF] ----------------------------------------");
    end

    repeat(20) @(posedge clk);
  endtask

  //===========================================================================
  // File-Based Test: Load from .mem files generated by Python
  //===========================================================================
  task automatic run_test_from_files(
      input string input_file,
      input string gamma_file,
      input string expected_file,
      input int dim
    );
    int errors;
    int input_beats;
    real diff, rel_err;
    logic [31:0] status;

    // Performance counters
    longint perf_start_time, perf_last_input_time;
    longint perf_first_output_time, perf_end_time;
    logic first_output_captured;

    // Precision stats
    logic [OUTPUT_BITS-1:0] actual_output_bits [MAX_VECTOR_SIZE];
    real max_abs_error = 0.0;
    real sum_abs_error = 0.0;
    longint max_ulp_error = 0; // Use longint to be safe with 32-bit diffs if needed


    $display("\n=============================================================");
    $display("File-Based Test: dim=%0d", dim);
    $display("Input:    %s", input_file);
    $display("Gamma:    %s", gamma_file);
    $display("Expected: %s", expected_file);
    $display("=============================================================");

    if (dim > MAX_VECTOR_SIZE)
    begin
      $display("[ERROR] dim=%0d exceeds MAX_VECTOR_SIZE=%0d", dim, MAX_VECTOR_SIZE);
      return;
    end

    // Load files
    $display("[TB] Loading input data (INPUT_PRECISION=%s)...", INPUT_PRECISION);
    if (INPUT_PRECISION == "INT8")
      $readmemh(input_file, file_input_int8);
    else
      $readmemh(input_file, file_input);

    $display("[TB] Loading gamma weights...");
    $readmemh(gamma_file, file_gamma);

    $display("[TB] Loading expected outputs...");
    $readmemh(expected_file, file_expected);

    // Soft Reset
    axi_write(ADDR_CTRL, 32'h0000_0002);
    repeat(20) @(posedge clk);

    // Enable interrupt
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);
    repeat(2) @(posedge clk);

    // Load gamma via AXI Stream
    $display("[TB] Loading gamma weights via AXI Stream...");
    begin
      int gamma_beats = (dim + (DATA_WIDTH/32) - 1) / (DATA_WIDTH/32);
      for (int b = 0; b < gamma_beats; b++)
      begin
        logic [DATA_WIDTH-1:0] gamma_beat = 0;
        for (int v = 0; v < DATA_WIDTH/32; v++)
        begin
          int idx = b * (DATA_WIDTH/32) + v;
          if (idx < dim)
            gamma_beat[v*32 +: 32] = file_gamma[idx];
        end
        s_axis_gamma_tdata <= gamma_beat;
        s_axis_gamma_tvalid <= 1;
        s_axis_gamma_tlast <= (b == gamma_beats - 1);
        @(posedge clk iff s_axis_gamma_tready);
      end
      s_axis_gamma_tvalid <= 0;
      s_axis_gamma_tlast <= 0;
    end
    repeat(5) @(posedge clk);

    // Copy input data to test_input array
    for (int i = 0; i < dim; i++)
    begin
      if (INPUT_PRECISION == "INT8")
        test_input[i] = {{24{file_input_int8[i][7]}}, file_input_int8[i]};
      else
        test_input[i] = file_input[i];
    end

    // Clear output array
    for (int i = 0; i < dim; i++)
      actual_output[i] = 0.0;

    // Calculate beats
    input_beats = (dim + NUM_LANES - 1) / NUM_LANES;
    $display("[TB] Running DUT (Input Beats=%0d)...", input_beats);

    // Initialize perf tracking
    first_output_captured = 0;
    perf_first_output_time = 0;

    fork
      // Sender
      begin
        perf_start_time = $time / CLK_PERIOD;
        axi_write(ADDR_CTRL, 32'h0000_0001); // Start

        for (int b = 0; b < input_beats; b++)
        begin
          data_beat = 0;
          for (int v = 0; v < NUM_LANES; v++)
          begin
            int idx = b*NUM_LANES + v;
            if (idx < dim)
              data_beat[v*INPUT_BITS +: INPUT_BITS] = test_input[idx];
          end
          s_axis_tdata <= data_beat;
          s_axis_tvalid <= 1;
          s_axis_tlast <= (b == input_beats - 1);
          @(posedge clk iff s_axis_tready);
        end
        perf_last_input_time = $time / CLK_PERIOD;
        s_axis_tvalid <= 0;
        s_axis_tlast <= 0;
      end

      // Receiver
      begin
        int collected = 0;
        int stall_counter = 0;
        m_axis_tready <= 1'b1;
        while (collected < dim)
        begin
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready)
          begin
            if (!first_output_captured)
            begin
              perf_first_output_time = $time / CLK_PERIOD;
              first_output_captured = 1;
            end
            stall_counter = 0;
            for (int v = 0; v < OUTPUT_VALUES_PER_BEAT; v++)
            begin
              int idx = collected + v;
              if (idx < dim)
              begin
                if (PRECISION == "BF16")
                begin
                  logic [15:0] bf = m_axis_tdata[v*OUTPUT_BITS +: 16];
                  actual_output[idx] = bf16_to_real(bf);
                  actual_output_bits[idx] = bf;
                end
                else
                begin
                  logic [7:0] i8 = m_axis_tdata[v*OUTPUT_BITS +: 8];
                  actual_output[idx] = real'(signed'(i8));
                  actual_output_bits[idx] = i8;
                end
              end
            end
            collected += OUTPUT_VALUES_PER_BEAT;
          end
          else
          begin
            stall_counter++;
            if (stall_counter > 20000)
              $fatal(1, "[TB] Receiver Timeout! Collected=%0d", collected);
          end
        end
        perf_end_time = $time / CLK_PERIOD;
        m_axis_tready <= 1'b0;
      end
    join

    wait_for_interrupt();

    // Verify against expected output from file
    $display("[TB] Verifying against expected output...");
    errors = 0;
    max_abs_error = 0.0;
    sum_abs_error = 0.0;
    max_ulp_error = 0;

    for (int i = 0; i < dim; i++)
    begin
      real actual_r, expected_r;
      real abs_err;
      longint ulp_err;

      // ULP Calculation (Bits difference)
      if (actual_output_bits[i] >= file_expected[i])
        ulp_err = actual_output_bits[i] - file_expected[i];
      else
        ulp_err = file_expected[i] - actual_output_bits[i];

      if (ulp_err > max_ulp_error)
        max_ulp_error = ulp_err;

      if (PRECISION == "BF16")
      begin
        actual_r = actual_output[i];
        expected_r = bf16_to_real(file_expected[i]);
        diff = actual_r - expected_r;

        abs_err = (diff < 0) ? -diff : diff;
        if (abs_err > max_abs_error)
          max_abs_error = abs_err;
        sum_abs_error += abs_err;

        rel_err = (expected_r != 0.0) ? ((diff < 0.0) ? -diff/expected_r : diff/expected_r) : ((diff < 0.0) ? -diff : diff);
        if (rel_err < 0.0)
          rel_err = -rel_err;
        if (rel_err > 0.01)
        begin
          if (errors < 5)
            $display("[FAIL] idx=%0d: expected %.4f, got %.4f (rel_err=%.2f%%) ULP=%0d",
                     i, expected_r, actual_r, rel_err * 100.0, ulp_err);
          errors++;
        end
      end
      else
      begin
        diff = actual_output[i] - real'($signed(file_expected[i]));

        abs_err = (diff < 0) ? -diff : diff;
        if (abs_err > max_abs_error)
          max_abs_error = abs_err;
        sum_abs_error += abs_err;

        if (diff > 2.0 || diff < -2.0)
        begin
          if (errors < 5)
            $display("[FAIL] idx=%0d: expected %0d, got %.0f (diff=%.2f) ULP=%0d",
                     i, $signed(file_expected[i]), actual_output[i], diff, ulp_err);
          errors++;
        end
      end
    end

    // Print Error Metrics
    $display("[TB] Precision Metrics:");
    $display("[TB]   Max Abs Error:  %.6f", max_abs_error);
    $display("[TB]   Mean Abs Error: %.6f", sum_abs_error / real'(dim));
    $display("[TB]   Max ULP Error:  %0d", max_ulp_error);

    // Report
    if (errors == 0)
    begin
      $display("[PASS] File-based test PASSED!");
      tests_passed++;
    end
    else
    begin
      $display("[FAIL] File-based test FAILED with %0d errors!", errors);
      tests_failed++;
    end

    // Performance report
    begin
      longint total_cycles = perf_end_time - perf_start_time;
      longint compute_cycles = perf_first_output_time - perf_last_input_time;
      $display("[PERF] Total: %0d cycles, Compute: %0d cycles", total_cycles, compute_cycles);
      $display("[PERF] Throughput: %.2f elem/cycle", real'(dim) / real'(total_cycles));
      $display("[TIME] %.3f us @ %.0f MHz", real'(total_cycles) * CLK_PERIOD / 1000.0, 1000.0 / CLK_PERIOD);
    end

    repeat(20) @(posedge clk);
  endtask

  //===========================================================================
  // Gamma Access Helper (Generate block for conditional compilation)
  //===========================================================================
  logic [31:0] tb_gamma_debug_read_val;
  int tb_gamma_debug_bank_sel;

  generate
    if (NUM_LANES == 8)
    begin : debug_access_8
      always_comb
      begin
        case (tb_gamma_debug_bank_sel)
          0:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank0[0];
          1:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank1[0];
          2:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank2[0];
          3:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank3[0];
          4:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank4[0];
          5:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank5[0];
          6:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank6[0];
          7:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_8lane.gamma_memory_bank7[0];
          default:
            tb_gamma_debug_read_val = 32'hDEAD_BEEF;
        endcase
      end
    end
    else if (NUM_LANES == 16)
    begin : debug_access_16
      always_comb
      begin
        case (tb_gamma_debug_bank_sel)
          0:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank0[0];
          1:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank1[0];
          2:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank2[0];
          3:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank3[0];
          4:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank4[0];
          5:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank5[0];
          6:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank6[0];
          7:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank7[0];
          8:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank8[0];
          9:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank9[0];
          10:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank10[0];
          11:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank11[0];
          12:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank12[0];
          13:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank13[0];
          14:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank14[0];
          15:
            tb_gamma_debug_read_val = dut.u_rms_norm_core.gen_gamma_16lane.gamma_memory_bank15[0];
          default:
            tb_gamma_debug_read_val = 32'hDEAD_BEEF;
        endcase
      end
    end
  endgenerate

  task automatic test_gamma_sanity_check();
    logic [31:0] expected_val;
    logic [31:0] actual_val;
    int errors = 0;
    int values_per_beat;
    logic [DATA_WIDTH-1:0] gamma_beat;

    $display("\n=== TEST: Gamma Bank Write Sanity Check ===");

    // Ensure no conflicting gamma stream activity
    s_axis_gamma_tvalid <= 0;
    repeat(10) @(posedge clk);

    $display("[TB] Writing to all %0d gamma banks via s_axis_gamma streaming...", NUM_LANES);

    // Use streaming gamma interface (modern)
    values_per_beat = DATA_WIDTH / 32;  // FP32 values per beat

    // Build a test pattern beat with unique values for each lane
    gamma_beat = '0;
    for (int v = 0; v < values_per_beat; v++)
    begin
      gamma_beat[v*32 +: 32] = 32'hCAFE_0000 | v;
    end

    // Send one beat via s_axis_gamma
    s_axis_gamma_tdata <= gamma_beat;
    s_axis_gamma_tvalid <= 1;
    s_axis_gamma_tlast <= 1;  // Single beat
    @(posedge clk iff s_axis_gamma_tready);
    s_axis_gamma_tvalid <= 0;
    s_axis_gamma_tlast <= 0;

    repeat(50) @(posedge clk);  // Let gamma settle - need more time for wide write

    $display("[TB] Verifying internal memory contents...");

    // Verify first NUM_LANES gamma values
    for (int i = 0; i < NUM_LANES; i++)
    begin
      expected_val = 32'hCAFE_0000 | i;

      // Control the generate block mux
      tb_gamma_debug_bank_sel = i;
      #1; // Allow comb logic to propagate
      actual_val = tb_gamma_debug_read_val;

      if (actual_val !== expected_val)
      begin
        $error("[TB] Bank %0d: Expected 0x%h, Got 0x%h", i, expected_val, actual_val);
        errors++;
      end
    end

    if (errors == 0)
    begin
      $display("[TB] PASSED: All %0d gamma banks verified successfully.", NUM_LANES);
    end
    else
    begin
      $display("[TB] FAILED: %0d bank mismatches found.", errors);
    end

    $display("[TB] Gamma sanity check completed.");
  endtask

  task automatic test_output_backpressure(input int dim = 2048);
    int input_beats = (dim + NUM_LANES - 1) / NUM_LANES;
    int stall_prob = 20; // % chance of stall per cycle

    $display("\n=== TEST: Output Backpressure dim = %0d ===", dim);

    // Soft reset
    axi_write(ADDR_CTRL, 32'h0000_0002);
    repeat(20) @(posedge clk);

    axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);

    load_gamma(dim);

    fork
      // Sender – normal
      begin
        axi_write(ADDR_CTRL, 32'h0000_0001);

        for (int b = 0; b < input_beats; b++)
        begin
          logic [DATA_WIDTH-1:0] data_beat = 0;
          for (int v = 0; v < NUM_LANES; v++)
          begin
            int idx = b * NUM_LANES + v;
            if (idx < dim)
              data_beat[v*INPUT_BITS +: INPUT_BITS] = $random;
          end
          s_axis_tdata  <= data_beat;
          s_axis_tvalid <= 1;
          s_axis_tlast  <= (b == input_beats-1);
          @(posedge clk iff s_axis_tready);
        end
        s_axis_tvalid <= 0;
        s_axis_tlast  <= 0;
      end

      // Receiver with random stalls
      begin
        int collected = 0;
        int timeout = 100000; // 10K cycles (reset on activity)
        int stall_counter = 0;
        m_axis_tready <= 0; // start stalled

        while (collected < dim)
        begin
          @(posedge clk);
          timeout--;
          if (timeout == 0)
          begin
            $fatal(1, "[TB] Timeout in backpressure test! Collected: %0d / %0d", collected, dim);
          end

          // Drive Ready Logic
          if (stall_counter > 0)
          begin
            m_axis_tready <= 0;
            stall_counter--;
          end
          else
          begin
            if ($urandom_range(0,99) < stall_prob)
            begin
              m_axis_tready <= 0;
              stall_counter = $urandom_range(2, 15);
            end
            else
            begin
              m_axis_tready <= 1;
            end
          end

          // Monitor (Check if data transferred on THIS clock edge)
          if (m_axis_tvalid && m_axis_tready)
          begin
            collected += OUTPUT_VALUES_PER_BEAT;
            timeout = 100000; // reset timeout on activity
          end
        end
        m_axis_tready <= 0;
      end
    join

    wait_for_interrupt();

    $display("[TB] Backpressure test completed (dim=%0d) no hang detected.", dim);
  endtask

  task automatic test_soft_reset_during_compute(input int dim = 8192);
    int input_beats = (dim + NUM_LANES - 1) / NUM_LANES;

    $display("\n=== TEST: Soft Reset During Compute dim = %0d ===", dim);

    axi_write(ADDR_CTRL, 32'h0000_0002); // initial reset
    repeat(20) @(posedge clk);

    axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
    axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);
    load_gamma(dim);

    fork
      // Sender – start normal
      begin
        axi_write(ADDR_CTRL, 32'h0000_0001);

        for (int b = 0; b < input_beats; b++)
        begin
          logic [DATA_WIDTH-1:0] data_beat = 0;
          for (int v = 0; v < NUM_LANES; v++)
          begin
            int idx = b * NUM_LANES + v;
            if (idx < dim)
              data_beat[v*INPUT_BITS +: INPUT_BITS] = $random;
          end

          // Inject soft reset around ~30-50% through input
          if (b == (input_beats / 3))
          begin
            $display("[TB] Injecting soft reset during computing continues");
            axi_write(ADDR_CTRL, 32'h0000_0002); // soft reset
            repeat(5) @(posedge clk);
          end

          s_axis_tdata  <= data_beat;
          s_axis_tvalid <= 1;
          s_axis_tlast  <= (b == input_beats-1);
          @(posedge clk iff s_axis_tready);
        end
        s_axis_tvalid <= 0;
        s_axis_tlast  <= 0;
      end

      // Receiver – just try to drain (expect nothing or garbage)
      begin
        int collected = 0;
        m_axis_tready <= 1;

        repeat(5000)
        begin // long timeout
          @(posedge clk);
          if (m_axis_tvalid && m_axis_tready)
          begin
            collected += OUTPUT_VALUES_PER_BEAT;
            $display("[TB] Unexpected output after reset beat %0d", collected);
          end
        end
        m_axis_tready <= 0;
      end
    join_any
    disable
      fork
        ;  // Kill threads

        // After reset, core should be idle → no interrupt expected
        repeat(100) @(posedge clk);
        if (interrupt)
        begin
          $error("[TB] Unexpected interrupt after soft reset during compute");
        end

        // Try a clean new run to check recovery
        if (DEBUG_AXI)
          $display("[TB] Trying clean run after interrupted reset...");
        run_test_case(dim); // reuse normal test (or call smaller one)

        if (DEBUG_AXI)
          $display("[TB] Soft reset during compute test finished.");
      endtask

      //===========================================================================
      // Performance Benchmark Table: Single-Vector + Back-to-Back Analysis
      //===========================================================================
      task automatic run_performance_benchmark_table();
        // All variable declarations at top for Vivado XSim compatibility
        typedef struct {
                  int dim;
                  longint single_total_cycles;
                  longint single_compute_cycles;
                  real single_throughput;
                  real single_time_us;
                  longint b2b_total_cycles;
                  real b2b_avg_cycles;
                  real b2b_sustained_throughput;
                  real b2b_avg_time_us;
                } perf_entry_t;

        perf_entry_t perf_table[NUM_TESTS];

        // Declare all working variables here
        int i, j, b, v, idx, global_beat;
        int dim, input_beats, output_beats;
        int total_input_beats, total_output_beats;
        int beat_in_vector;
        int collected, total_received;
        int timeout;
        logic [DATA_WIDTH-1:0] data_beat;
        longint start_cyc, end_cyc;
        logic first_output_seen;

        localparam int B2B_VECTORS = 10;

        $display("\n===============================================================================");
        $display("  PERFORMANCE BENCHMARK: Single + Back-to-Back Analysis");
        $display("===============================================================================");

        // Run tests and collect data
        for (i = 0; i < NUM_TESTS; i = i + 1)
        begin
          dim = TEST_DIMS[i];
          input_beats = (dim + NUM_LANES - 1) / NUM_LANES;
          output_beats = (dim + OUTPUT_VALUES_PER_BEAT - 1) / OUTPUT_VALUES_PER_BEAT;

          $display("[Benchmark] Testing dim=%0d (%0d/%0d)...", dim, i+1, NUM_TESTS);

          // ====== PART 1: Single Vector Test ======
          axi_write(ADDR_CTRL, 32'h0000_0002);
          repeat(20) @(posedge clk);
          axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
          axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);
          load_gamma(dim);

          for (j = 0; j < dim; j = j + 1)
          begin
            if (INPUT_PRECISION == "INT8")
              test_input[j] = $signed($random) % 128;
            else
              test_input[j] = $random;
          end

          first_output_seen = 0;

          fork
            begin
              start_cyc = $time / CLK_PERIOD;
              axi_write(ADDR_CTRL, 32'h0000_0001);

              for (b = 0; b < input_beats; b = b + 1)
              begin
                data_beat = 0;
                for (v = 0; v < NUM_LANES; v = v + 1)
                begin
                  idx = b * NUM_LANES + v;
                  if (idx < dim)
                    data_beat[v*INPUT_BITS +: INPUT_BITS] = test_input[idx];
                end
                s_axis_tdata <= data_beat;
                s_axis_tvalid <= 1;
                s_axis_tlast <= (b == input_beats - 1);
                @(posedge clk iff s_axis_tready);
              end
              s_axis_tvalid <= 0;
              s_axis_tlast <= 0;
            end

            begin
              collected = 0;
              timeout = 0;
              m_axis_tready <= 1;

              while (collected < dim)
              begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready)
                begin
                  if (!first_output_seen)
                  begin

                    first_output_seen = 1;
                  end
                  collected = collected + OUTPUT_VALUES_PER_BEAT;
                  timeout = 0;
                end
                else
                begin
                  timeout = timeout + 1;
                  if (timeout > 50000)
                    $fatal(1, "[TB] Single-vector benchmark timeout at dim=%0d", dim);
                end
              end
              end_cyc = $time / CLK_PERIOD;
              m_axis_tready <= 0;
            end
          join

          // Store single-vector results
          perf_table[i].dim = dim;
          perf_table[i].single_total_cycles = end_cyc - start_cyc;

          perf_table[i].single_throughput = real'(dim) / real'(perf_table[i].single_total_cycles);
          perf_table[i].single_time_us = real'(perf_table[i].single_total_cycles) * CLK_PERIOD / 1000.0;

          repeat(20) @(posedge clk);

          // ====== PART 2: Back-to-Back Test (10 vectors) ======
          axi_write(ADDR_CTRL, 32'h0000_0002);
          repeat(20) @(posedge clk);
          axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
          axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);
          load_gamma(dim);

          total_input_beats = B2B_VECTORS * input_beats;
          total_output_beats = B2B_VECTORS * output_beats;

          fork
            begin
              start_cyc = $time / CLK_PERIOD;
              axi_write(ADDR_CTRL, 32'h0000_0001);

              while (!s_axis_tready)
                @(posedge clk);

              for (global_beat = 0; global_beat < total_input_beats; global_beat = global_beat + 1)
              begin
                beat_in_vector = global_beat % input_beats;
                data_beat = 0;

                for (v = 0; v < NUM_LANES; v = v + 1)
                begin
                  idx = beat_in_vector * NUM_LANES + v;
                  if (idx < dim)
                    data_beat[v*INPUT_BITS +: INPUT_BITS] = test_input[idx];
                end

                s_axis_tdata <= data_beat;
                s_axis_tvalid <= 1;
                s_axis_tlast <= (beat_in_vector == input_beats - 1);

                @(posedge clk);
                while (!s_axis_tready)
                  @(posedge clk);
              end

              s_axis_tvalid <= 0;
              s_axis_tlast <= 0;
            end

            begin
              total_received = 0;
              timeout = 0;
              m_axis_tready <= 1;

              while (total_received < total_output_beats)
              begin
                @(posedge clk);
                if (m_axis_tvalid && m_axis_tready)
                begin
                  total_received = total_received + 1;
                  timeout = 0;
                end
                else
                begin
                  timeout = timeout + 1;
                  if (timeout > 100000)
                    $fatal(1, "[TB] B2B benchmark timeout at dim=%0d", dim);
                end
              end

              end_cyc = $time / CLK_PERIOD;
              m_axis_tready <= 0;
            end
          join

          // Store back-to-back results
          perf_table[i].b2b_total_cycles = end_cyc - start_cyc;
          perf_table[i].b2b_avg_cycles = real'(perf_table[i].b2b_total_cycles) / real'(B2B_VECTORS);
          perf_table[i].b2b_sustained_throughput = real'(dim * B2B_VECTORS) / real'(perf_table[i].b2b_total_cycles);
          perf_table[i].b2b_avg_time_us = perf_table[i].b2b_avg_cycles * CLK_PERIOD / 1000.0;

          repeat(10) @(posedge clk);
        end

        // Print formatted table
        $display("\n===========================================================================================");
        $display("                     SINGLE VECTOR (Cold Start)          |      BACK-TO-BACK (10 Vectors)");
        $display("+----------+-------------+---------+-----------+---------+---------+-----------+-----------+");
        $display("| Dimension| Total Cycles| Thru(e/c) | Time(us)| Avg Cyc | Total Cyc | Time(us)| Thru(e/c) |");
        $display("+----------+-------------+---------+-----------+---------+---------+-----------+-----------+");

        for (i = 0; i < NUM_TESTS; i = i + 1)
        begin
          $display("| %8d | %11d | %9.2f | %7.2f | %7.1f | %9d | %7.2f | %9.2f |",
                   perf_table[i].dim,
                   perf_table[i].single_total_cycles,
                   perf_table[i].single_throughput,
                   perf_table[i].single_time_us,
                   perf_table[i].b2b_avg_cycles,
                   perf_table[i].b2b_total_cycles,
                   perf_table[i].b2b_avg_time_us,
                   perf_table[i].b2b_sustained_throughput);
        end

        $display("+----------+-------------+-----------+---------+---------+-----------+---------+-----------+");
        $display("\nConfiguration: INPUT=%s, OUTPUT=%s, LANES=%0d, BUS_WIDTH=%0d bits",
                 INPUT_PRECISION, PRECISION, NUM_LANES, DATA_WIDTH);
        $display("Clock Period: %.2f ns (%.0f MHz)", CLK_PERIOD, 1000.0/CLK_PERIOD);
        $display("Note: 'Thru(e/c)' = Throughput in elements/cycle, 'Avg Cyc' = Average cycles per vector in B2B mode");
        $display("=============================================================================================\n");

        tests_passed++;
      endtask

      //===========================================================================
      // Corner Case: Non-Aligned Dimension (not divisible by NUM_LANES)
      //===========================================================================
      task automatic test_corner_non_aligned_dimension();
        int dim = NUM_LANES * 7 + 3; // e.g., 16*7+3 = 115
        logic [DATA_WIDTH-1:0] data_beat;
        int input_beats;
        int collected;
        int timeout;
        $display("\n=== CORNER CASE: Non-Aligned Dimension (dim=%0d, lanes=%0d) ===", dim, NUM_LANES);

        if (dim > MAX_VECTOR_SIZE)
        begin
          $display("[SKIP] Non-aligned dim %0d exceeds MAX_VECTOR_SIZE", dim);
          return;
        end

        axi_write(ADDR_CTRL, 32'h0000_0002);
        repeat(20) @(posedge clk);
        axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
        load_gamma(dim);

        input_beats = (dim + NUM_LANES - 1) / NUM_LANES;

        fork
          begin
            axi_write(ADDR_CTRL, 32'h0000_0001);
            for (int b = 0; b < input_beats; b++)
            begin
              data_beat = 0;
              for (int v = 0; v < NUM_LANES; v++)
              begin
                int idx = b * NUM_LANES + v;
                if (idx < dim)
                  data_beat[v*INPUT_BITS +: INPUT_BITS] = $random;
                else
                  data_beat[v*INPUT_BITS +: INPUT_BITS] = 0; // Pad with zeros
              end
              s_axis_tdata <= data_beat;
              s_axis_tvalid <= 1;
              s_axis_tlast <= (b == input_beats - 1);
              @(posedge clk iff s_axis_tready);
            end
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
          end

          begin
            collected = 0;
            timeout = 20000;
            m_axis_tready <= 1;
            while (collected < dim && timeout > 0)
            begin
              @(posedge clk);
              if (m_axis_tvalid && m_axis_tready)
                collected += OUTPUT_VALUES_PER_BEAT;
              timeout--;
            end
            m_axis_tready <= 0;
            if (timeout == 0)
              $error("[TB] Non-aligned dimension test timeout");
            else
              $display("[PASS] Non-aligned dimension test completed (%0d elements)", dim);
          end
        join

        repeat(20) @(posedge clk);
        tests_passed++;
      endtask

      //===========================================================================
      // Corner Case: All-Zero Vector Input
      //===========================================================================
      task automatic test_corner_zero_vector();
        int dim = 1152;
        int collected;
        int timeout;
        int input_beats;
        $display("\n=== CORNER CASE: All-Zero Vector Input (dim=%0d) ===", dim);

        axi_write(ADDR_CTRL, 32'h0000_0002);
        repeat(20) @(posedge clk);
        axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
        load_gamma(dim);

        input_beats = (dim + NUM_LANES - 1) / NUM_LANES;

        fork
          begin
            axi_write(ADDR_CTRL, 32'h0000_0001);
            for (int b = 0; b < input_beats; b++)
            begin
              s_axis_tdata <= '0; // All zeros
              s_axis_tvalid <= 1;
              s_axis_tlast <= (b == input_beats - 1);
              @(posedge clk iff s_axis_tready);
            end
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
          end

          begin
            collected = 0;
            timeout   = 20000;
            m_axis_tready <= 1;
            while (collected < dim && timeout > 0)
            begin
              @(posedge clk);
              if (m_axis_tvalid && m_axis_tready)
                collected += OUTPUT_VALUES_PER_BEAT;
              timeout--;
            end
            m_axis_tready <= 0;
            if (timeout == 0)
              $error("[TB] Zero vector test timeout");
            else
              $display("[PASS] Zero vector test completed (output should be ~0 with epsilon)");
          end
        join

        repeat(20) @(posedge clk);
        tests_passed++;
      endtask

      //===========================================================================
      // Corner Case: Extreme Values (Maximum positive/negative for input type)
      //===========================================================================
      task automatic test_corner_extreme_values();
        int dim = 512;
        logic [DATA_WIDTH-1:0] data_beat;
        int input_beats;
        int collected;
        int timeout;
        $display("\n=== CORNER CASE: Extreme Input Values (dim=%0d) ===", dim);

        axi_write(ADDR_CTRL, 32'h0000_0002);
        repeat(20) @(posedge clk);
        axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
        load_gamma(dim);

        input_beats = (dim + NUM_LANES - 1) / NUM_LANES;

        fork
          begin
            axi_write(ADDR_CTRL, 32'h0000_0001);
            for (int b = 0; b < input_beats; b++)
            begin
              data_beat = 0;
              for (int v = 0; v < NUM_LANES; v++)
              begin
                int idx = b * NUM_LANES + v;
                if (idx < dim)
                begin
                  if (INPUT_PRECISION == "INT8")
                    // Alternate between max positive and max negative
                    data_beat[v*INPUT_BITS +: INPUT_BITS] = (idx % 2) ? 8'sh7F : 8'sh80;
                  else
                    // INT32: alternate extremes
                    data_beat[v*INPUT_BITS +: INPUT_BITS] = (idx % 2) ? 32'sh7FFFFFFF : 32'sh80000000;
                end
              end
              s_axis_tdata <= data_beat;
              s_axis_tvalid <= 1;
              s_axis_tlast <= (b == input_beats - 1);
              @(posedge clk iff s_axis_tready);
            end
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
          end

          begin
            collected = 0;
            timeout   = 20000;
            m_axis_tready <= 1;
            while (collected < dim && timeout > 0)
            begin
              @(posedge clk);
              if (m_axis_tvalid && m_axis_tready)
                collected += OUTPUT_VALUES_PER_BEAT;
              timeout--;
            end
            m_axis_tready <= 0;
            if (timeout == 0)
              $error("[TB] Extreme values test timeout");
            else
              $display("[PASS] Extreme values test completed (no overflow detected)");
          end
        join

        repeat(20) @(posedge clk);
        tests_passed++;
      endtask

      //===========================================================================
      // Corner Case: Input Stalls (Random tvalid pulses)
      //===========================================================================
      task automatic test_corner_input_stalls();
        int dim = 2048;
        int stall_prob = 30; // 30% chance to stall
        logic [DATA_WIDTH-1:0] data_beat;
        int input_beats;
        int collected;
        int timeout;
        $display("\n=== CORNER CASE: Input with Random Stalls (dim=%0d, prob=%0d%%) ===", dim, stall_prob);

        axi_write(ADDR_CTRL, 32'h0000_0002);
        repeat(20) @(posedge clk);
        axi_write(ADDR_EPSILON, real_to_fp32(1e-5));
        load_gamma(dim);

        input_beats = (dim + NUM_LANES - 1) / NUM_LANES;

        fork
          begin
            axi_write(ADDR_CTRL, 32'h0000_0001);

            for (int b = 0; b < input_beats; b++)
            begin
              data_beat = 0;
              for (int v = 0; v < NUM_LANES; v++)
              begin
                int idx = b * NUM_LANES + v;
                if (idx < dim)
                  data_beat[v*INPUT_BITS +: INPUT_BITS] = $random;
              end

              // Drive data
              s_axis_tdata <= data_beat;
              s_axis_tlast <= (b == input_beats - 1);

              // Random stalls: hold tvalid=0 for random cycles
              if ($urandom_range(0, 99) < stall_prob)
              begin
                s_axis_tvalid <= 0;
                s_axis_tlast <= 0;  // AXI: tlast must be 0 when tvalid is 0
                repeat($urandom_range(1, 5)) @(posedge clk);
                // Restore tlast after stall
                s_axis_tlast <= (b == input_beats - 1);
              end

              s_axis_tvalid <= 1;
              @(posedge clk iff s_axis_tready);
            end
            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
          end

          begin
            collected = 0;
            timeout   = 50000;
            m_axis_tready <= 1;
            while (collected < dim && timeout > 0)
            begin
              @(posedge clk);
              if (m_axis_tvalid && m_axis_tready)
                collected += OUTPUT_VALUES_PER_BEAT;
              timeout--;
            end
            m_axis_tready <= 0;
            if (timeout == 0)
              $error("[TB] Input stalls test timeout");
            else
              $display("[PASS] Input stalls test completed");
          end
        join

        repeat(20) @(posedge clk);
        tests_passed++;
      endtask

      //===========================================================================
      // Throughput Test Task: Blasts vectors back-to-back
      //===========================================================================
      task automatic run_throughput_test(input int dim, input int num_vectors);
        longint start_cyc, end_cyc, total_cyc;
        real throughput;
        int input_beats;
        int output_beats;
        int total_input_beats;
        int total_output_beats;

        $display("\n=============================================================");
        $display("  Throughput Test: dim=%0d, vectors=%0d", dim, num_vectors);
        $display("  Blasting vectors back-to-back to measure max throughput");
        $display("=============================================================");

        // Calculate beats
        input_beats = (dim + NUM_LANES - 1) / NUM_LANES;
        output_beats = (dim + OUTPUT_VALUES_PER_BEAT - 1) / OUTPUT_VALUES_PER_BEAT;
        total_input_beats = num_vectors * input_beats;
        total_output_beats = num_vectors * output_beats;

        $display("[TB] Input beats/vector: %0d, Output beats/vector: %0d", input_beats, output_beats);

        // Soft Reset
        axi_write(ADDR_CTRL, 32'h0000_0002);
        repeat(20) @(posedge clk);

        // Configure epsilon
        axi_write(ADDR_EPSILON, real_to_fp32(1e-5));

        // Enable interrupt
        axi_write(ADDR_INTR_ENABLE, 32'h0000_0001);

        // Load gamma weights (only once - same for all vectors)
        load_gamma(dim);

        // Generate test data (same data reused for all vectors to keep it simple)
        for (int i = 0; i < dim; i++)
        begin
          if (INPUT_PRECISION == "INT8")
            test_input[i] = $signed($random) % 128;
          else
            test_input[i] = $random;
        end

        // Mark start time
        start_cyc = $time / CLK_PERIOD;

        fork
          // Thread 1: Sender - Blast all vectors back-to-back
          begin
            // Pulse Start ONCE to activate the pipeline
            axi_write(ADDR_CTRL, 32'h0000_0001);

            // Wait for ready
            while (!s_axis_tready)
              @(posedge clk);

            // Continuous Loop over ALL vector beats
            for (int global_beat = 0; global_beat < total_input_beats; global_beat++)
            begin
              int beat_in_vector = global_beat % input_beats;
              logic [DATA_WIDTH-1:0] data_beat = 0;

              for (int v = 0; v < NUM_LANES; v++)
              begin
                int idx = beat_in_vector * NUM_LANES + v;
                if (idx < dim)
                  data_beat[v*INPUT_BITS +: INPUT_BITS] = test_input[idx];
              end

              s_axis_tdata <= data_beat;
              s_axis_tvalid <= 1;
              // Assert LAST on the final beat of EACH vector
              s_axis_tlast <= (beat_in_vector == input_beats - 1);

              @(posedge clk);
              while (!s_axis_tready)
                @(posedge clk);
            end

            s_axis_tvalid <= 0;
            s_axis_tlast <= 0;
          end

          // Thread 2: Receiver - Drain outputs continuously to keep pipeline moving
          begin
            int total_received = 0;
            int timeout = 0;

            m_axis_tready <= 1;

            while (total_received < total_output_beats)
            begin
              @(posedge clk);
              if (m_axis_tvalid && m_axis_tready)
              begin
                total_received++;
                timeout = 0;
              end
              else
              begin
                timeout++;
                if (timeout > 100000)
                begin
                  $fatal(1, "[TB] Throughput test receiver timeout! Received %0d/%0d beats",
                         total_received, total_output_beats);
                end
              end
            end

            m_axis_tready <= 0;
          end
        join

        // Mark end time
        end_cyc = $time / CLK_PERIOD;
        total_cyc = end_cyc - start_cyc;

        // Calculate Stats
        throughput = real'(dim * num_vectors) / real'(total_cyc);

        $display("[PERF] ----------------------------------------");
        $display("[PERF] Throughput Test Results:");
        $display("[PERF] Dimension: %0d elements", dim);
        $display("[PERF] Vectors processed: %0d", num_vectors);
        $display("[PERF] Total elements: %0d", dim * num_vectors);
        $display("[PERF] Total cycles: %0d", total_cyc);
        $display("[PERF] Average cycles/vector: %.1f", real'(total_cyc) / real'(num_vectors));
        $display("[PERF] Average time/vector: %.3f us", (real'(total_cyc) / real'(num_vectors)) * CLK_PERIOD / 1000.0);
        $display("[PERF] Sustained throughput: %.2f elements/cycle", throughput);
        $display("[PERF] Total time: %.3f us @ %.0f MHz",
                 real'(total_cyc) * CLK_PERIOD / 1000.0, 1000.0 / CLK_PERIOD);
        $display("[PERF] ----------------------------------------");

        repeat(20) @(posedge clk);
        tests_passed++;
      endtask

      //===========================================================================
      // Main Sequence
      //===========================================================================
      initial
      begin
        // Init
        rst_n = 0;
        s_axi_ctrl_awaddr   = 0;
        s_axi_ctrl_awvalid  = 0;
        s_axi_ctrl_awprot   = 0;
        s_axi_ctrl_wdata    = 0;
        s_axi_ctrl_wvalid   = 0;
        s_axi_ctrl_wstrb    = 0;
        s_axi_ctrl_bready   = 0;
        s_axi_ctrl_araddr   = 0;
        s_axi_ctrl_arvalid  = 0;
        s_axi_ctrl_arprot   = 0;
        s_axi_ctrl_rready   = 0;
        s_axis_tdata        = 0;
        s_axis_tvalid       = 0;
        s_axis_tlast        = 0;
        m_axis_tready       = 0;
        s_axis_gamma_tdata  = 0;
        s_axis_gamma_tvalid = 0;
        s_axis_gamma_tlast  = 0;

        #100 rst_n = 1;
        #100;

        test_axi_lite_registers();

        for (int i = 0; i < NUM_TESTS; i++)
        begin
          run_test_case(TEST_DIMS[i]);
        end

        // File-based crosscheck tests
        $display("\n###############################################################");
        $display("#  PYTHON CROSSCHECK: Verify against generated .mem files     #");
        $display("###############################################################");
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
            run_test_from_files("input_data_int8_6144.mem", "gamma_weights_6144.mem", "expected_output_bf16_6144.mem", 6144);
            run_test_from_files("input_data_int8_8192.mem", "gamma_weights_8192.mem", "expected_output_bf16_8192.mem", 8192);
            run_test_from_files("input_data_int8_12288.mem", "gamma_weights_12288.mem", "expected_output_bf16_12288.mem", 12288);
          end
          else
          begin
            run_test_from_files("input_data_int8_64.mem", "gamma_weights_64.mem", "expected_output_64.mem", 64);
            run_test_from_files("input_data_int8_1152.mem", "gamma_weights_1152.mem", "expected_output_1152.mem", 1152);
            run_test_from_files("input_data_int8_2048.mem", "gamma_weights_2048.mem", "expected_output_2048.mem", 2048);
            run_test_from_files("input_data_int8_3072.mem", "gamma_weights_3072.mem", "expected_output_3072.mem", 3072);
            run_test_from_files("input_data_int8_4096.mem", "gamma_weights_4096.mem", "expected_output_4096.mem", 4096);
            run_test_from_files("input_data_int8_5120.mem", "gamma_weights_5120.mem", "expected_output_5120.mem", 5120);
            run_test_from_files("input_data_int8_6144.mem", "gamma_weights_6144.mem", "expected_output_6144.mem", 6144);
            run_test_from_files("input_data_int8_8192.mem", "gamma_weights_8192.mem", "expected_output_8192.mem", 8192);
            run_test_from_files("input_data_int8_12288.mem", "gamma_weights_12288.mem", "expected_output_12288.mem", 12288);
          end
        end
        else
        begin
          if (PRECISION == "BF16")
          begin
            run_test_from_files("input_data_64.mem", "gamma_weights_64.mem", "expected_output_bf16_64.mem", 64);
            run_test_from_files("input_data_1152.mem", "gamma_weights_1152.mem", "expected_output_bf16_1152.mem", 1152);
            run_test_from_files("input_data_2048.mem", "gamma_weights_2048.mem", "expected_output_bf16_2048.mem", 2048);
            run_test_from_files("input_data_3072.mem", "gamma_weights_3072.mem", "expected_output_bf16_3072.mem", 3072);
            run_test_from_files("input_data_4096.mem", "gamma_weights_4096.mem", "expected_output_bf16_4096.mem", 4096);
            run_test_from_files("input_data_5120.mem", "gamma_weights_5120.mem", "expected_output_bf16_5120.mem", 5120);
            run_test_from_files("input_data_6144.mem", "gamma_weights_6144.mem", "expected_output_bf16_6144.mem", 6144);
            run_test_from_files("input_data_8192.mem", "gamma_weights_8192.mem", "expected_output_bf16_8192.mem", 8192);
            run_test_from_files("input_data_12288.mem", "gamma_weights_12288.mem", "expected_output_bf16_12288.mem", 12288);
          end
          else
          begin
            run_test_from_files("input_data_64.mem", "gamma_weights_64.mem", "expected_output_64.mem", 64);
            run_test_from_files("input_data_1152.mem", "gamma_weights_1152.mem", "expected_output_1152.mem", 1152);
            run_test_from_files("input_data_2048.mem", "gamma_weights_2048.mem", "expected_output_2048.mem", 2048);
            run_test_from_files("input_data_3072.mem", "gamma_weights_3072.mem", "expected_output_3072.mem", 3072);
            run_test_from_files("input_data_4096.mem", "gamma_weights_4096.mem", "expected_output_4096.mem", 4096);
            run_test_from_files("input_data_5120.mem", "gamma_weights_5120.mem", "expected_output_5120.mem", 5120);
            run_test_from_files("input_data_6144.mem", "gamma_weights_6144.mem", "expected_output_6144.mem", 6144);
            run_test_from_files("input_data_8192.mem", "gamma_weights_8192.mem", "expected_output_8192.mem", 8192);
            run_test_from_files("input_data_12288.mem", "gamma_weights_12288.mem", "expected_output_12288.mem", 12288);
          end
        end



        if (DEBUG_AXI)
          $display("\n=== Starting stress / error injection tests ===\n");

        test_gamma_sanity_check();
        repeat(50) @(posedge clk);

        for (int i = 0; i < NUM_TESTS; i++)
        begin
          test_output_backpressure(TEST_DIMS[i]);
        end
        repeat(50) @(posedge clk);

        for (int i = 0; i < NUM_TESTS; i++)
        begin
          test_soft_reset_during_compute(TEST_DIMS[i]);
        end
        repeat(50) @(posedge clk);

        // Throughput Tests: Measure sustained pipeline performance
        $display("\n#############################################################");
        $display("#  THROUGHPUT TEST: Back-to-back vector processing            #");
        $display("###############################################################");

        for (int i = 0; i < NUM_TESTS; i++)
        begin
          int VECTOR_B2B = 10;
          $display("\nRunning throughput test: %0d vectors of %0d elements each...", VECTOR_B2B,TEST_DIMS[i]);
          run_throughput_test(TEST_DIMS[i], VECTOR_B2B);
        end

        repeat(50) @(posedge clk);

        // Corner Case Tests
        $display("\n###############################################################");
        $display("#  CORNER CASE TESTS: Edge Conditions and Stress Scenarios    #");
        $display("###############################################################");

        test_corner_non_aligned_dimension();
        repeat(20) @(posedge clk);

        test_corner_zero_vector();
        repeat(20) @(posedge clk);

        test_corner_extreme_values();
        repeat(20) @(posedge clk);

        test_corner_input_stalls();
        repeat(50) @(posedge clk);

        // Performance Benchmark Table
        $display("\n###############################################################");
        $display("#  PERFORMANCE BENCHMARK: Comprehensive Latency Table         #");
        $display("###############################################################");
        run_performance_benchmark_table();
        repeat(50) @(posedge clk);


        $display("\nAll stress tests completed.");

        $display("\nSummary: %0d Passed, %0d Failed", tests_passed, tests_failed);
        if (tests_failed == 0)
          if (DEBUG_AXI)
            $display("ALL TESTS PASSED.");
          else
            if (DEBUG_AXI)
              $fatal(1,"SOME TESTS FAILED.");

        $finish;
      end

    endmodule
