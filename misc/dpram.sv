module dpram #(
    parameter A_WID = 10,
    parameter D_WID = 32
  )
  (
    input  logic clka,
    input  logic clkb,
    input  logic wea,
    input  logic web,
    input  logic ena,
    input  logic enb,
    input  logic [A_WID-1:0] addra,
    input  logic [A_WID-1:0] addrb,
    input  logic [D_WID-1:0] dina, dinb,
    output logic [D_WID-1:0] douta, doutb
  );

  (* ram_style = "block" *)
  logic [D_WID-1:0] mem [2**A_WID-1:0] = '{default: '0};

  always @ (posedge clka)
  begin
    if (ena)
    begin
      douta <= mem[addra];
      if(wea)
        mem[addra] <= dina;
    end
  end

  always @ (posedge clkb)
  begin
    if (enb)
    begin
      doutb <= mem[addrb];
      if(web)
        mem[addrb] <= dinb;
    end
  end

endmodule
