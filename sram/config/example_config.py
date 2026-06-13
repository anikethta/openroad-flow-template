# Data word size
word_size = 8
# Number of words in the memory
num_words = 256
# Sky130 arrays include one replica/dummy row/column for the 1RW port.
# Add one spare row/column so row and column totals stay even.
num_spare_rows = 1
num_spare_cols = 1

# Technology to use in $OPENRAM_TECH
tech_name = "sky130"
# Use tools already available on PATH instead of requiring Nix.
use_nix = False
# Process corners to characterize
process_corners = [ "TT" ]
# Voltage corners to characterize
supply_voltages = [ 1.8 ]
# Temperature corners to characterize
temperatures = [ 25 ]

# Output directory for the results
output_path = "temp"
# Output file base name
output_name = "sram_256x8"

# Disable analytical models for full characterization (WARNING: slow!)
# analytical_delay = False

# To force this to use magic and netgen for DRC/LVS/PEX
# Could be calibre for FreePDK45
drc_name = "magic"
lvs_name = "netgen"
pex_name = "magic"
