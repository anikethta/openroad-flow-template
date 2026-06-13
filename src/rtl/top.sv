module top (  
// expose fifo I/O to top-level
  input  logic             clk,
  input  logic             rst,
  input  logic             wr_en,
  input  logic             rd_en,
  input  logic [7:0]       din,
  output logic [7:0]       dout,
  output logic [7:0]        sram_test_dout,
  output logic             full,
  output logic             empty
);

// instantiate fifo
  fifo #(
    .DEPTH(16),
    .WIDTH(8)
  ) fifo_inst ( 
    .* 
  );

endmodule
