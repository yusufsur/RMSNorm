`timescale 1ns / 1ps
///////////////////////////////////////////////////////////////////////////////
// RMSNorm AXI Wrapper
//
// Description:
//   Wraps the core rms_norm accelerator with an AXI4-Lite control interface.
//   Exposes AXI4-Stream interfaces for high-bandwidth data movement.
//
// AXI4-Stream Interfaces:
//   s_axis_*       : Input data stream (DATA_WIDTH-bit, INT32 or INT8)
//   m_axis_*       : Output data stream (DATA_WIDTH-bit, BF16 or INT8)
//   s_axis_gamma_* : Gamma weight loading (DATA_WIDTH-bit = DATA_WIDTH/32 x FP32 per beat)
//                    Total beats: ceil(MAX_VECTOR_SIZE / (DATA_WIDTH/32))
//
// Address Map (AXI4-Lite):
//   0x00: Control Register (RW)
//         Bit 0: Start (Write 1 to pulse start)
//         Bit 1: Soft Reset (Write 1 to pulse reset, self-clearing)
//   0x04: Status Register (RO)
//         Bit 0: Busy
//         Bit 1: Done (latched until new start or reset)
//   0x08: Interrupt Enable Register (RW)
//         Bit 0: Done Interrupt Enable
//   0x0C: Interrupt Status Register (RW1C)
//         Bit 0: Done Interrupt
//   0x10: Epsilon Configuration (RW)
//         32-bit IEEE 754 Floating Point Value
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
// Engineer: Yusuf SUR
// Email: yusuf.sur@sabanciuniv.edu
// Date: 2026-01-22
///////////////////////////////////////////////////////////////////////////////

module rms_norm_axi_wrapper #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 16, 
    // Core Parameters
    parameter MAX_VECTOR_SIZE   = 12288,
    parameter NUM_LANES         = 16,
    parameter DATA_WIDTH        = 512,
    parameter USE_DSP           = 1,
    parameter DEBUG             = 0,
    parameter DEBUG_CYCLES      = 0,
    parameter DEBUG_FIFO_DEPTH  = 0,
    parameter INPUT_PRECISION   = "INT8",
    parameter PRECISION         = "BF16"
  )(
    // Clock and Reset
    input  logic                                aclk,
    input  logic                                aresetn,

    // Interrupt Output
    output logic                                interrupt,

    // AXI4-Lite Control Interface
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_ctrl_awaddr,
    input  logic [2:0]                          s_axi_ctrl_awprot,
    input  logic                                s_axi_ctrl_awvalid,
    output logic                                s_axi_ctrl_awready,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]       s_axi_ctrl_wdata,
    input  logic [C_S_AXI_DATA_WIDTH/8-1:0]     s_axi_ctrl_wstrb,
    input  logic                                s_axi_ctrl_wvalid,
    output logic                                s_axi_ctrl_wready,
    output logic [1:0]                          s_axi_ctrl_bresp,
    output logic                                s_axi_ctrl_bvalid,
    input  logic                                s_axi_ctrl_bready,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]       s_axi_ctrl_araddr,
    input  logic [2:0]                          s_axi_ctrl_arprot,
    input  logic                                s_axi_ctrl_arvalid,
    output logic                                s_axi_ctrl_arready,
    output logic [C_S_AXI_DATA_WIDTH-1:0]       s_axi_ctrl_rdata,
    output logic [1:0]                          s_axi_ctrl_rresp,
    output logic                                s_axi_ctrl_rvalid,
    input  logic                                s_axi_ctrl_rready,

    // AXI4-Stream Slave (Input Data)
    input  logic [DATA_WIDTH-1:0]               s_axis_tdata,
    input  logic                                s_axis_tvalid,
    output logic                                s_axis_tready,
    input  logic                                s_axis_tlast,

    // AXI4-Stream Master (Output Data)
    output logic [DATA_WIDTH-1:0]               m_axis_tdata,
    output logic                                m_axis_tvalid,
    input  logic                                m_axis_tready,
    output logic                                m_axis_tlast,

    // AXI4-Stream Slave (Gamma Weights - High-Speed)
    input  logic [DATA_WIDTH-1:0]               s_axis_gamma_tdata,
    input  logic                                s_axis_gamma_tvalid,
    output logic                                s_axis_gamma_tready,
    input  logic                                s_axis_gamma_tlast
  );

  initial
    if (DATA_WIDTH < NUM_LANES * ((INPUT_PRECISION == "INT8") ? 8 : 32))
      $fatal(1, "DATA_WIDTH (%0d) must be >= NUM_LANES (%0d) * INPUT_BITS (%0d)", DATA_WIDTH, NUM_LANES, (INPUT_PRECISION == "INT8") ? 8 : 32);

  // Debug prints (when enabled)
  generate
    if (DEBUG)
    begin : gen_debug_prints
      always @(posedge aclk)
      begin
        if (core_start)
          $display("[WRAPPER] T=%0t: core_start PULSE", $time);
        if (core_done)
          $display("[WRAPPER] T=%0t: core_done PULSE", $time);
        if (soft_reset_sync)
          $display("[WRAPPER] T=%0t: soft_reset_sync ACTIVE", $time);
      end
    end
  endgenerate

  //=========================================================================
  // Internal Signals
  //=========================================================================

  // Core interface
  logic        core_start;
  logic        core_done;
  logic        core_busy;
  logic [31:0] core_epsilon;


  // Wide gamma streaming
  logic                    core_gamma_busy;
  logic                    core_gamma_we_wide;
  logic [15:0]             core_gamma_addr_wide;
  logic [DATA_WIDTH-1:0]   core_gamma_wdata_wide;
  logic [15:0]             gamma_stream_addr;

  // Reset & control
  logic        core_rst_n;
  logic        soft_reset;
  logic        soft_reset_sync;  // registered version

  logic        reg_done;
  logic        reg_intr_enable;
  logic        reg_intr_status;

  logic [31:0] reg_epsilon;      // 0x10

  // AXI-Lite write pipeline
  logic [C_S_AXI_ADDR_WIDTH-1:0] write_addr;
  logic                          write_addr_valid;
  logic [31:0]                   write_data;
  logic [3:0]                    write_strb;
  logic                          write_data_valid;

  // AXI-Lite response signals
  logic        axi_awready;
  logic        axi_wready;
  logic [1:0]  axi_bresp;
  logic        axi_bvalid;
  logic        axi_arready;
  logic [31:0] axi_rdata;
  logic [1:0]  axi_rresp;
  logic        axi_rvalid;

  // Address map
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CTRL         = 'h0000;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS       = 'h0004;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_INTR_ENABLE  = 'h0008;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_INTR_STATUS  = 'h000C;
  localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_EPSILON      = 'h0010;


  //=========================================================================
  // Soft Reset
  //=========================================================================
  logic [15:0] soft_reset_extender;

  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      soft_reset_extender <= '0;
    end
    else
    begin
      if (soft_reset)
        soft_reset_extender <= '1;
      else
        soft_reset_extender <= {1'b0, soft_reset_extender[15:1]};
    end
  end

  assign soft_reset_sync = |soft_reset_extender;

  assign core_rst_n = aresetn & ~soft_reset_sync;

  //=========================================================================
  // Interrupt Logic
  //=========================================================================
  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      reg_intr_status <= 1'b0;
    end
    else if (soft_reset_sync || core_start)
    begin
      reg_intr_status <= 1'b0;
    end
    else if (core_done)
    begin
      reg_intr_status <= 1'b1;
    end
    else if (write_addr_valid && write_data_valid &&
             (write_addr == ADDR_INTR_STATUS) &&
             write_strb[0] && write_data[0])
    begin
      reg_intr_status <= 1'b0;
    end
  end

  assign interrupt = reg_intr_status & reg_intr_enable;

  //=========================================================================
  // Gamma Streaming DMA
  //=========================================================================
  // Calculate max gamma address based on configuration
  localparam GAMMA_VALUES_PER_BEAT = DATA_WIDTH / 32;
  localparam GAMMA_MAX_ADDR = (MAX_VECTOR_SIZE + GAMMA_VALUES_PER_BEAT - 1) / GAMMA_VALUES_PER_BEAT - 1;

  assign s_axis_gamma_tready = !core_gamma_busy;

  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      gamma_stream_addr   <= '0;
      core_gamma_we_wide  <= 1'b0;
      core_gamma_addr_wide<= '0;
      core_gamma_wdata_wide<= '0;
    end
    else if (soft_reset_sync)
    begin
      gamma_stream_addr   <= '0;
      core_gamma_we_wide  <= 1'b0;
    end
    else
    begin
      core_gamma_we_wide <= 1'b0;

      if (s_axis_gamma_tvalid && s_axis_gamma_tready)
      begin
        core_gamma_we_wide   <= 1'b1;
        core_gamma_addr_wide <= gamma_stream_addr;
        core_gamma_wdata_wide<= s_axis_gamma_tdata;

        if (s_axis_gamma_tlast)
          gamma_stream_addr <= '0;
        else if (gamma_stream_addr < GAMMA_MAX_ADDR)
          gamma_stream_addr <= gamma_stream_addr + 1;
        // else: saturate at max to prevent overflow
      end
    end
  end

  //=========================================================================
  // AXI4-Lite Slave
  //=========================================================================
  assign s_axi_ctrl_awready = axi_awready;
  assign s_axi_ctrl_wready  = axi_wready;
  assign s_axi_ctrl_bresp   = axi_bresp;
  assign s_axi_ctrl_bvalid  = axi_bvalid;
  assign s_axi_ctrl_arready = axi_arready;
  assign s_axi_ctrl_rdata   = axi_rdata;
  assign s_axi_ctrl_rresp   = axi_rresp;
  assign s_axi_ctrl_rvalid  = axi_rvalid;

  //=========================================================================
  // WRITE ADDRESS CHANNEL
  //=========================================================================
  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      axi_awready      <= 1'b0;
      write_addr       <= '0;
      write_addr_valid <= 1'b0;
    end
    else if (soft_reset_sync)
    begin
      axi_awready      <= 1'b0;
      write_addr       <= '0;
      write_addr_valid <= 1'b0;
    end
    else
    begin
      axi_awready <= 1'b0;

      if (!axi_awready && s_axi_ctrl_awvalid && !write_addr_valid)
      begin
        axi_awready      <= 1'b1;
        write_addr       <= s_axi_ctrl_awaddr;
        write_addr_valid <= 1'b1;
      end
      // Clear write_addr_valid after response accepted
      else if (axi_bvalid && s_axi_ctrl_bready)
      begin
        write_addr_valid <= 1'b0;
      end
    end
  end

  //=========================================================================
  // WRITE DATA CHANNEL
  //=========================================================================
  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      axi_wready       <= 1'b0;
      write_data       <= '0;
      write_strb       <= '0;
      write_data_valid <= 1'b0;
    end
    else if (soft_reset_sync)
    begin
      axi_wready       <= 1'b0;
      write_data       <= '0;
      write_strb       <= '0;
      write_data_valid <= 1'b0;
    end
    else
    begin
      axi_wready <= 1'b0;

      if (!axi_wready && s_axi_ctrl_wvalid && !write_data_valid)
      begin
        axi_wready       <= 1'b1;
        write_data       <= s_axi_ctrl_wdata;
        write_strb       <= s_axi_ctrl_wstrb;
        write_data_valid <= 1'b1;
      end
      // Clear write_data_valid after response accepted
      else if (axi_bvalid && s_axi_ctrl_bready)
      begin
        write_data_valid <= 1'b0;
      end
    end
  end

  //=========================================================================
  // WRITE RESPONSE + REGISTER UPDATES
  //=========================================================================
  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      axi_bvalid       <= 1'b0;
      axi_bresp        <= 2'b00;
      reg_epsilon      <= 32'h3727C5AC; // ~1e-5
      reg_done         <= 1'b0;
      reg_intr_enable  <= 1'b0;
      soft_reset       <= 1'b0;
      core_start       <= 1'b0;
    end
    else
    begin

      // Defaults
      core_start     <= 1'b0;
      soft_reset     <= 1'b0;

      // Latch done pulse
      if (core_done)
        reg_done <= 1'b1;

      // Commit write transaction
      if (write_addr_valid && write_data_valid && !axi_bvalid)
      begin

        axi_bvalid <= 1'b1;
        axi_bresp  <= 2'b00; // OKAY default

        case (write_addr)
          ADDR_CTRL:
          begin
            if (write_strb[0])
            begin
              if (write_data[0])
              begin
                core_start <= 1'b1;
                reg_done   <= 1'b0;
              end
              if (write_data[1])
              begin
                soft_reset <= 1'b1;
                reg_done   <= 1'b0;
              end
            end
          end

          ADDR_INTR_ENABLE:
          begin
            if (write_strb[0])
              reg_intr_enable <= write_data[0];
          end

          ADDR_INTR_STATUS:
          begin
            // RW1C handled in interrupt block
          end

          ADDR_EPSILON:
          begin
            if (write_strb[0])
              reg_epsilon[ 7:0] <= write_data[ 7:0];
            if (write_strb[1])
              reg_epsilon[15:8] <= write_data[15:8];
            if (write_strb[2])
              reg_epsilon[23:16]<= write_data[23:16];
            if (write_strb[3])
              reg_epsilon[31:24]<= write_data[31:24];
          end

          default:
          begin
            // Invalid address
            axi_bresp <= 2'b10; // SLVERR
          end
        endcase
      end

      // Clear response after accepted
      if (axi_bvalid && s_axi_ctrl_bready)
      begin
        axi_bvalid <= 1'b0;
      end
    end
  end

  assign core_epsilon = reg_epsilon;

  //=========================================================================
  // READ CHANNEL
  //=========================================================================
  always_ff @(posedge aclk or negedge aresetn)
  begin
    if (!aresetn)
    begin
      axi_arready <= 1'b0;
      axi_rvalid  <= 1'b0;
      axi_rresp   <= 2'b00;
      axi_rdata   <= '0;
    end
    else if (soft_reset_sync)
    begin
      axi_arready <= 1'b0;
      axi_rvalid  <= 1'b0;
      axi_rresp   <= 2'b00;
      axi_rdata   <= '0;
    end
    else
    begin
      axi_arready <= 1'b0;

      if (!axi_arready && s_axi_ctrl_arvalid && !axi_rvalid)
      begin
        axi_arready <= 1'b1;
      end

      if (axi_arready && s_axi_ctrl_arvalid && !axi_rvalid)
      begin
        axi_rvalid <= 1'b1;
        axi_rresp  <= 2'b00;
        axi_rdata  <= 32'h0;

        case (s_axi_ctrl_araddr)
          ADDR_CTRL:
            axi_rdata <= 32'h0; // write-only
          ADDR_STATUS:
            axi_rdata <= {30'b0, reg_done, core_busy};
          ADDR_INTR_ENABLE:
            axi_rdata <= {31'b0, reg_intr_enable};
          ADDR_INTR_STATUS:
            axi_rdata <= {31'b0, reg_intr_status};
          ADDR_EPSILON:
            axi_rdata <= reg_epsilon;

          default:
          begin
            // Invalid address
            axi_rresp <= 2'b10; // SLVERR
          end
        endcase
      end

      if (axi_rvalid && s_axi_ctrl_rready)
      begin
        axi_rvalid <= 1'b0;
      end
    end
  end

  //=========================================================================
  // Core Instantiation
  //=========================================================================
  rms_norm #(
             .MAX_VECTOR_SIZE (MAX_VECTOR_SIZE),
             .NUM_LANES       (NUM_LANES),
             .DATA_WIDTH      (DATA_WIDTH),
             .USE_DSP         (USE_DSP),
             .DEBUG           (DEBUG),
             .DEBUG_CYCLES    (DEBUG_CYCLES),
             .DEBUG_FIFO_DEPTH(DEBUG_FIFO_DEPTH),
             .INPUT_PRECISION (INPUT_PRECISION),
             .PRECISION       (PRECISION)
           ) u_rms_norm_core (
             .clk                (aclk),
             .rst_n              (core_rst_n),

             .s_axis_tdata       (s_axis_tdata),
             .s_axis_tvalid      (s_axis_tvalid),
             .s_axis_tready      (s_axis_tready),
             .s_axis_tlast       (s_axis_tlast),

             .m_axis_tdata       (m_axis_tdata),
             .m_axis_tvalid      (m_axis_tvalid),
             .m_axis_tready      (m_axis_tready),
             .m_axis_tlast       (m_axis_tlast),

             .start              (core_start),
             .done               (core_done),
             .busy               (core_busy),

             .cfg_epsilon        (core_epsilon),


             .gamma_we_wide      (core_gamma_we_wide),
             .gamma_addr_wide    (core_gamma_addr_wide),
             .gamma_wdata_wide   (core_gamma_wdata_wide),
             .gamma_busy         (core_gamma_busy)
           );

`include "axi_assertions.svh"

endmodule
