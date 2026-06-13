module fifo_storage #(
  parameter integer DEPTH,
  parameter integer WIDTH
) (
  input  logic                          clk,
  input  logic                          wr_en,
  input  logic [$clog2(DEPTH)-1:0]      w_addr,
  input  logic [$clog2(DEPTH)-1:0]      r_addr,
  input  logic [WIDTH-1:0]              din,
  output logic [WIDTH-1:0]              dout
);

  logic [WIDTH-1:0] mem [DEPTH-1:0];

  assign dout = mem[r_addr];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      mem[w_addr] <= din;
    end
  end
endmodule

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
  output logic [7:0]       sram_test_dout,
  output logic             full,
  output logic             empty
);

  localparam ADDR_BITS = $clog2(DEPTH);

  logic [ADDR_BITS:0] w_ptr;
  logic [ADDR_BITS:0] r_ptr;
  logic               fifo_wr_en;
  logic [7:0]         sram_addr;

  assign empty = w_ptr == r_ptr;
  assign full  = (r_ptr == {~w_ptr[ADDR_BITS], w_ptr[ADDR_BITS-1:0]});
  assign fifo_wr_en = wr_en && (!full || (full && rd_en));
  assign sram_addr = w_ptr[ADDR_BITS-1:0];

  // instantiate DFF array for main storage
  fifo_storage #(
    .DEPTH(DEPTH),
    .WIDTH(WIDTH)
  ) storage_inst (
    .clk(clk),
    .wr_en(fifo_wr_en),
    .w_addr(w_ptr[ADDR_BITS-1:0]),
    .r_addr(r_ptr[ADDR_BITS-1:0]),
    .din(din),
    .dout(dout)
  );

  // instantiate sram macro, this doesn't do anything for the FIFO per se, I'm just testing what the synthesis/pnr tools do with it
  sram_256x8_stub sram_storage (
    .clk0(clk),
    .csb0(1'b0),
    .web0(~fifo_wr_en),
    .addr0(sram_addr),
    .din0(din[7:0]),
    .dout0(sram_test_dout)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      w_ptr <= '0;
      r_ptr <= '0;
    end else begin
      if (fifo_wr_en) begin
        w_ptr <= w_ptr + 1'b1;
      end

      if (rd_en && !empty) begin
        r_ptr <= r_ptr + 1'b1;
      end
    end
  end
endmodule