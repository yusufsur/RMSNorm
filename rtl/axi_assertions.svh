// =====================================================================
// axi_assertions.svh
// AXI4-Lite Slave + AXI4-Stream Protocol Assertions
// For use with rms_norm_axi_wrapper (wrapper is slave)
// =====================================================================

`ifndef AXI_ASSERTIONS_SVH
`define AXI_ASSERTIONS_SVH

`ifndef SYNTHESIS

// =========================================================================
// AXI4-Lite Protocol Assertions (Wrapper is Slave)
// =========================================================================

// Helper handshake signals
logic axi_aw_hs, axi_w_hs, axi_b_hs;
logic axi_ar_hs, axi_r_hs;

assign axi_aw_hs = s_axi_ctrl_awvalid && s_axi_ctrl_awready;
assign axi_w_hs  = s_axi_ctrl_wvalid  && s_axi_ctrl_wready;
assign axi_b_hs  = s_axi_ctrl_bvalid  && s_axi_ctrl_bready;
assign axi_ar_hs = s_axi_ctrl_arvalid && s_axi_ctrl_arready;
assign axi_r_hs  = s_axi_ctrl_rvalid  && s_axi_ctrl_rready;

// VALID must stay asserted until handshake (bounded timeout)
assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_awvalid |-> ##[0:1000] axi_aw_hs
                ) else
         $error("AXI-Lite: AWVALID not acknowledged within 1000 cycles");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_wvalid |-> ##[0:1000] axi_w_hs
                ) else
         $error("AXI-Lite: WVALID not acknowledged within 1000 cycles");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_bvalid |-> ##[0:1000] axi_b_hs
                ) else
         $error("AXI-Lite: BVALID not acknowledged within 1000 cycles");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_arvalid |-> ##[0:1000] axi_ar_hs
                ) else
         $error("AXI-Lite: ARVALID not acknowledged within 1000 cycles");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_rvalid |-> ##[0:1000] axi_r_hs
                ) else
         $error("AXI-Lite: RVALID not acknowledged within 1000 cycles");

// VALID must not drop before handshake
assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_awvalid && !axi_aw_hs |=> s_axi_ctrl_awvalid
                ) else
         $error("AXI-Lite: AWVALID dropped before handshake");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_wvalid && !axi_w_hs |=> s_axi_ctrl_wvalid
                ) else
         $error("AXI-Lite: WVALID dropped before handshake");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_bvalid && !axi_b_hs |=> s_axi_ctrl_bvalid
                ) else
         $error("AXI-Lite: BVALID dropped before handshake");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_arvalid && !axi_ar_hs |=> s_axi_ctrl_arvalid
                ) else
         $error("AXI-Lite: ARVALID dropped before handshake");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axi_ctrl_rvalid && !axi_r_hs |=> s_axi_ctrl_rvalid
                ) else
         $error("AXI-Lite: RVALID dropped before handshake");

// Data/Address stability (only after VALID was already high)
assert property (@(posedge aclk) disable iff (!aresetn)
                 $past(s_axi_ctrl_awvalid) && s_axi_ctrl_awvalid && !axi_aw_hs |->
                 $stable({s_axi_ctrl_awaddr, s_axi_ctrl_awprot})
                ) else
         $error("AXI-Lite: AWADDR/AWPROT changed while AWVALID high");

assert property (@(posedge aclk) disable iff (!aresetn)
                 $past(s_axi_ctrl_arvalid) && s_axi_ctrl_arvalid && !axi_ar_hs |->
                 $stable({s_axi_ctrl_araddr, s_axi_ctrl_arprot})
                ) else
         $error("AXI-Lite: ARADDR/ARPROT changed while ARVALID high");

assert property (@(posedge aclk) disable iff (!aresetn)
                 $past(s_axi_ctrl_wvalid) && s_axi_ctrl_wvalid && !axi_w_hs |->
                 $stable({s_axi_ctrl_wdata, s_axi_ctrl_wstrb})
                ) else
         $error("AXI-Lite: WDATA/WSTRB changed while WVALID high");

assert property (@(posedge aclk) disable iff (!aresetn)
                 $past(s_axi_ctrl_bvalid) && s_axi_ctrl_bvalid && !axi_b_hs |->
                 $stable(s_axi_ctrl_bresp)
                ) else
         $error("AXI-Lite: BRESP changed while BVALID high");

assert property (@(posedge aclk) disable iff (!aresetn)
                 $past(s_axi_ctrl_rvalid) && s_axi_ctrl_rvalid && !axi_r_hs |->
                 $stable({s_axi_ctrl_rdata, s_axi_ctrl_rresp})
                ) else
         $error("AXI-Lite: RDATA/RRESP changed while RVALID high");

// =========================================================================
// AXI4-Stream Protocol Assertions
// =========================================================================

logic s_data_hs, m_data_hs, gamma_hs;

assign s_data_hs  = s_axis_tvalid && s_axis_tready;
assign m_data_hs  = m_axis_tvalid && m_axis_tready;
assign gamma_hs   = s_axis_gamma_tvalid && s_axis_gamma_tready;

// TVALID must not drop before handshake
// Disabled during soft_reset_sync since tvalid will drop when core resets
assert property (@(posedge aclk) disable iff (!aresetn || soft_reset_sync)
                 s_axis_tvalid && !s_data_hs |=> s_axis_tvalid
                ) else
         $error("s_axis: tvalid dropped before handshake");

assert property (@(posedge aclk) disable iff (!aresetn || soft_reset_sync)
                 m_axis_tvalid && !m_data_hs |=> m_axis_tvalid
                ) else
         $error("m_axis: tvalid dropped before handshake");

assert property (@(posedge aclk) disable iff (!aresetn || soft_reset_sync)
                 s_axis_gamma_tvalid && !gamma_hs |=> s_axis_gamma_tvalid
                ) else
         $error("s_axis_gamma: tvalid dropped before handshake");

// Data stability during backpressure (only after VALID was already high)
// Disabled during soft_reset_sync since data is expected to change during reset
assert property (@(posedge aclk) disable iff (!aresetn || soft_reset_sync)
                 $past(s_axis_tvalid) && s_axis_tvalid && $past(!s_axis_tready) && !s_axis_tready |->
                 $stable({s_axis_tdata, s_axis_tlast})
                ) else
         $error("s_axis: tdata/tlast unstable during backpressure");

assert property (@(posedge aclk) disable iff (!aresetn || soft_reset_sync)
                 $past(m_axis_tvalid) && m_axis_tvalid && $past(!m_axis_tready) && !m_axis_tready |->
                 $stable({m_axis_tdata, m_axis_tlast})
                ) else
         $error("m_axis: tdata/tlast unstable during backpressure");

assert property (@(posedge aclk) disable iff (!aresetn || soft_reset_sync)
                 $past(s_axis_gamma_tvalid) && s_axis_gamma_tvalid && $past(!s_axis_gamma_tready) && !s_axis_gamma_tready |->
                 $stable({s_axis_gamma_tdata, s_axis_gamma_tlast})
                ) else
         $error("s_axis_gamma: tdata/tlast unstable during backpressure");

// TLAST must only be high when TVALID is high
assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axis_tlast |-> s_axis_tvalid
                ) else
         $error("s_axis: tlast high while tvalid low");

assert property (@(posedge aclk) disable iff (!aresetn)
                 m_axis_tlast |-> m_axis_tvalid
                ) else
         $error("m_axis: tlast high while tvalid low");

assert property (@(posedge aclk) disable iff (!aresetn)
                 s_axis_gamma_tlast |-> s_axis_gamma_tvalid
                ) else
         $error("s_axis_gamma: tlast high while tvalid low");

`endif // SYNTHESIS
`endif // AXI_ASSERTIONS_SVH