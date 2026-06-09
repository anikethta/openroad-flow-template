module fifo #(
  parameter integer DEPTH,
  parameter integer WIDTH
) (
  input  logic             clk,
  input  logic             rst,
  input  logic             wr_en,
  input  logic             rd_en,
  input  logic [WIDTH-1:0] din,
  output logic [WIDTH-1:0] dout,
  output logic             full,
  output logic             empty,
  input  logic             flush
);

  localparam ADDR_BITS = $clog2(DEPTH);

  logic [ADDR_BITS:0] w_ptr;
  logic [ADDR_BITS:0] r_ptr;
  logic [  WIDTH-1:0] mem   [DEPTH-1:0];

  assign empty = w_ptr == r_ptr;
  assign full  = (r_ptr == {~w_ptr[ADDR_BITS], w_ptr[ADDR_BITS-1:0]});
  assign dout  = mem[r_ptr[ADDR_BITS-1:0]];


  always_ff @(posedge clk) begin
    if (rst) begin
      w_ptr <= '0;
      r_ptr <= '0;
    end else if (flush) begin
      w_ptr <= '0;
      r_ptr <= '0;
    end else begin
      if (wr_en && (!full || (full && rd_en))) begin
        w_ptr                     <= w_ptr + 1'b1;
        mem[w_ptr[ADDR_BITS-1:0]] <= din;
      end

      if (rd_en && !empty) begin
        r_ptr <= r_ptr + 1'b1;
      end
    end
  end
endmodule