module top (  
// expose fifo I/O to top-level
  input  logic             clk,
  input  logic             rst,
  input  logic             wr_en,
  input  logic             rd_en,
  input  logic [31:0]       din,
  output logic [31:0]       dout,
  output logic             full,
  output logic             empty,
  input  logic             flush
);

// instantiate fifo
  fifo #(
    .DEPTH(16),
    .WIDTH(32)
  ) fifo_inst ( 
    .* 
  );

endmodule