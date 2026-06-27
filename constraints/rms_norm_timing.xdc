###############################################################################
# RMS Norm Timing Constraints - Out-of-Context Mode
#
# Description:
#   Constraints for OOC synthesis. IO paths are set as false paths
#   so timing analysis focuses on internal register-to-register paths.
#
# Target: xcku5p
# Engineer: Yusuf SUR
###############################################################################

#==============================================================================
# Clock Constraints
#==============================================================================

# Primary clock - approximately 385 MHz = 2.59 ns period is max of this design
create_clock -period 2.6 -name clk [get_ports aclk]

# Clock uncertainty (jitter + skew)
set_clock_uncertainty 0.100 [get_clocks aclk]


#==============================================================================
# Input/Output Delay Constraints
#==============================================================================
# AXI timing budget breakdown (example for 2.6ns clock period):
#   - Source/Dest reg delays: ~0.2-0.4ns
#   - Setup/Hold margins: ~0.1-0.2ns
#   Total budget: ~0.5-0.6ns per direction

set CLK_PERIOD 2.6
set INPUT_DELAY_MAX  [expr $CLK_PERIOD * 0.20]  ;# 20% of clock period (0.52ns)
set INPUT_DELAY_MIN  [expr $CLK_PERIOD * 0.05]  ;# 5% of clock period (0.13ns)
set OUTPUT_DELAY_MAX [expr $CLK_PERIOD * 0.20]  ;# 20% of clock period (0.52ns)
set OUTPUT_DELAY_MIN [expr $CLK_PERIOD * 0.05]  ;# 5% of clock period (0.13ns)

#------------------------------------------------------------------------------
# AXI4-Lite Control Interface (s_axi_ctrl_*)
#------------------------------------------------------------------------------
# Write Address Channel
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axi_ctrl_awaddr[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axi_ctrl_awaddr[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axi_ctrl_awprot[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axi_ctrl_awprot[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axi_ctrl_awvalid]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axi_ctrl_awvalid]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axi_ctrl_awready]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axi_ctrl_awready]

# Write Data Channel
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axi_ctrl_wdata[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axi_ctrl_wdata[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axi_ctrl_wstrb[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axi_ctrl_wstrb[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axi_ctrl_wvalid]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axi_ctrl_wvalid]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axi_ctrl_wready]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axi_ctrl_wready]

# Write Response Channel
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports {s_axi_ctrl_bresp[*]}]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports {s_axi_ctrl_bresp[*]}]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axi_ctrl_bvalid]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axi_ctrl_bvalid]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axi_ctrl_bready]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axi_ctrl_bready]

# Read Address Channel
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axi_ctrl_araddr[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axi_ctrl_araddr[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axi_ctrl_arprot[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axi_ctrl_arprot[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axi_ctrl_arvalid]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axi_ctrl_arvalid]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axi_ctrl_arready]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axi_ctrl_arready]

# Read Data Channel
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports {s_axi_ctrl_rdata[*]}]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports {s_axi_ctrl_rdata[*]}]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports {s_axi_ctrl_rresp[*]}]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports {s_axi_ctrl_rresp[*]}]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axi_ctrl_rvalid]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axi_ctrl_rvalid]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axi_ctrl_rready]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axi_ctrl_rready]

#------------------------------------------------------------------------------
# AXI4-Stream Input Data (s_axis_*)
#------------------------------------------------------------------------------
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axis_tdata[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axis_tdata[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axis_tvalid]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axis_tvalid]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axis_tlast]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axis_tlast]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axis_tready]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axis_tready]

#------------------------------------------------------------------------------
# AXI4-Stream Output Data (m_axis_*)
#------------------------------------------------------------------------------
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports {m_axis_tdata[*]}]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports {m_axis_tdata[*]}]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports m_axis_tvalid]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports m_axis_tvalid]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports m_axis_tlast]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports m_axis_tlast]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports m_axis_tready]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports m_axis_tready]

#------------------------------------------------------------------------------
# AXI4-Stream Gamma Weights (s_axis_gamma_*)
#------------------------------------------------------------------------------
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports {s_axis_gamma_tdata[*]}]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports {s_axis_gamma_tdata[*]}]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axis_gamma_tvalid]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axis_gamma_tvalid]
set_input_delay -clock aclk -max $INPUT_DELAY_MAX [get_ports s_axis_gamma_tlast]
set_input_delay -clock aclk -min $INPUT_DELAY_MIN [get_ports s_axis_gamma_tlast]
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports s_axis_gamma_tready]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports s_axis_gamma_tready]

#------------------------------------------------------------------------------
# Interrupt Output
#------------------------------------------------------------------------------
set_output_delay -clock aclk -max $OUTPUT_DELAY_MAX [get_ports interrupt]
set_output_delay -clock aclk -min $OUTPUT_DELAY_MIN [get_ports interrupt]

#==============================================================================
# Asynchronous Signals (False Paths)
#==============================================================================
# Reset is asynchronous - no timing relationship to clock
set_false_path -from [get_ports aresetn]


#==============================================================================
# Memory Style Directives
#==============================================================================
set_property RAM_STYLE BLOCK [get_cells -hierarchical -filter {NAME =~ "*bank*"}]
set_property RAM_STYLE BLOCK [get_cells -hierarchical -filter {NAME =~ "*gamma*"}]
