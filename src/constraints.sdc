create_clock -name clk -period 5.000 [get_ports clk]

set_input_delay 0.500 -clock [get_clocks clk] [get_ports {rst wr_en rd_en flush din[*]}]
set_output_delay 0.500 -clock [get_clocks clk] [get_ports {dout[*] full empty}]

set_clock_uncertainty 0.100 [get_clocks clk]
set_clock_transition 0.100 [get_clocks clk]
