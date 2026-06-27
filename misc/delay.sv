`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Delay Module with Reset Support
//////////////////////////////////////////////////////////////////////////////////

module delay #(
    parameter DLY = 1,
    parameter DW  = 1
)(
    input  logic            clk,
    input  logic            rst_n,
    input  logic            en,
    input  logic [DW-1:0]   din,
    output logic [DW-1:0]   dout
);

    logic [DW-1:0] samp [0:DLY-1];

    assign dout = samp[DLY-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Clear all delay stages on reset
            for (int i = 0; i < DLY; i++) begin
                samp[i] <= '0;
            end
        end
        else if (en) begin
            // Shift register
            samp[0] <= din;
            for (int i = 1; i < DLY; i++) begin
                samp[i] <= samp[i-1];
            end
        end
    end

endmodule