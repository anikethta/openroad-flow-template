#!/usr/bin/env python3
# See LICENSE for licensing information.
#
# Copyright (c) 2016-2024 Regents of the University of California and The Board
# of Regents for the Oklahoma Agricultural and Mechanical College
# (acting for and on behalf of Oklahoma State University)
# All rights reserved.
#
"""
SRAM Compiler

The output files append the given suffixes to the output name:
a spice (.sp) file for circuit simulation
a GDS2 (.gds) file containing the layout
a LEF (.lef) file for preliminary P&R (real one should be from layout)
a Liberty (.lib) file for timing analysis/optimization
"""

import sys
import os
import datetime
import math
import subprocess
import shutil

# You don't need the next two lines if you're sure that openram package is installed
# from common import *
# make_openram_package()

import openram
from openram import debug

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
DEFAULT_CONFIG_DIR = os.path.join(SCRIPT_DIR, "config")
SRAM_BUILD_DIR = os.path.join(PROJECT_DIR, "build", "sram")

OPENRAM_OPTIONS_WITH_VALUES = {
    "-o", "--output",
    "-p", "--outpath",
    "-j", "--threads",
    "-m", "--sim_threads",
    "-t", "--tech",
    "-s", "--spice",
}

def discover_config_files(path):
    if os.path.isdir(path):
        return [
            os.path.join(path, entry)
            for entry in sorted(os.listdir(path))
            if entry.endswith(".py") and not entry.startswith("_")
        ]
    return [path]

def split_driver_args(argv):
    openram_args = []
    config_paths = []
    idx = 0
    while idx < len(argv):
        arg = argv[idx]
        if arg in OPENRAM_OPTIONS_WITH_VALUES:
            openram_args.append(arg)
            idx += 1
            if idx >= len(argv):
                print("Missing value for {}".format(arg), file=sys.stderr)
                sys.exit(2)
            openram_args.append(argv[idx])
        elif arg.startswith("-"):
            openram_args.append(arg)
        else:
            config_paths.extend(discover_config_files(arg))
        idx += 1

    if not config_paths:
        config_paths = discover_config_files(DEFAULT_CONFIG_DIR)

    config_paths = [os.path.abspath(path) for path in config_paths]
    missing_configs = [path for path in config_paths if not os.path.isfile(path)]
    if missing_configs:
        for path in missing_configs:
            print("Config file not found: {}".format(path), file=sys.stderr)
        sys.exit(2)

    return openram_args, config_paths

def run_config_subprocess(openram_args, config_file):
    env = os.environ.copy()
    env["SRAM_COMPILER_CHILD"] = "1"
    cmd = [sys.executable, os.path.abspath(__file__)] + openram_args + [config_file]
    print("Generating SRAM from {}".format(config_file))
    return subprocess.call(cmd, env=env)

def clear_sram_build_dir():
    os.makedirs(SRAM_BUILD_DIR, exist_ok=True)
    for entry in os.listdir(SRAM_BUILD_DIR):
        path = os.path.join(SRAM_BUILD_DIR, entry)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path)
        else:
            os.remove(path)

if os.environ.get("SRAM_COMPILER_CHILD") != "1":
    openram_args, config_files = split_driver_args(sys.argv[1:])
    clear_sram_build_dir()
    if len(config_files) != 1:
        failed = []
        for config_file in config_files:
            return_code = run_config_subprocess(openram_args, config_file)
            if return_code != 0:
                failed.append((config_file, return_code))
        if failed:
            for config_file, return_code in failed:
                print("FAILED: {} exited with {}".format(config_file, return_code), file=sys.stderr)
            sys.exit(1)
        sys.exit(0)

    sys.argv = [sys.argv[0]] + openram_args + [config_files[0]]

(OPTS, args) = openram.parse_args()

# Check that we are left with a single configuration file as argument.
if len(args) != 1:
    print("Usage: sram_compiler.py [openram options] [config file | config directory]")
    print("If no config path is given, all .py files in sram/config are generated.")
    print(openram.USAGE)
    sys.exit(2)

# Set top process to openram
OPTS.top_process = 'openram'

# Parse config file and set up all the options
openram.init_openram(config_file=args[0])

# Keep generated SRAM collateral inside this project's build tree.
os.makedirs(SRAM_BUILD_DIR, exist_ok=True)
OPTS.output_path = os.path.join(SRAM_BUILD_DIR, "")

# Ensure that the right bitcell exists or use the parameterised one
openram.setup_bitcell()

# Only print banner here so it's not in unit tests
openram.print_banner()

# Keep track of running stats
start_time = datetime.datetime.now()
openram.print_time("Start", start_time)

# Output info about this run
openram.report_status()

debug.print_raw("Words per row: {}".format(OPTS.words_per_row))

output_extensions = ["lvs", "sp", "v", "lib", "py", "html", "log"]
# Only output lef/gds if back-end
if not OPTS.netlist_only:
    output_extensions.extend(["lef", "gds"])

output_files = ["{0}{1}.{2}".format(OPTS.output_path,
                                    OPTS.output_name, x)
                for x in output_extensions]
debug.print_raw("Output files are: ")
for path in output_files:
    debug.print_raw(path)

# Create an SRAM (we can also pass sram_config, see documentation/tutorials for details)
from openram import sram
s = sram()

# Output the files for the resulting SRAM
s.save()


# the generated SRAM verilog file is purely a simulation model and is non-synthesizable.
# thus, we need to generate stubs in src/rtl/util for the SRAM module
# during synthesis, we use the .lib to provide relevant information about the module
# TO-DO: running simulation requires us to switch over to the simulation--there probably is a better way to do it though
def verilog_range(width):
    if width <= 1:
        return ""
    return " [{}:0]".format(width - 1)

def zero_extend_signal(signal_name, from_width, to_width):
    if to_width == from_width:
        return signal_name
    if to_width < from_width:
        return "{}[{}:0]".format(signal_name, to_width - 1)
    return "{{{}'b0, {}}}".format(to_width - from_width, signal_name)

def write_sram_stub(sram_obj):
    logical_data_width = int(OPTS.word_size)
    physical_data_width = logical_data_width + int(OPTS.num_spare_cols or 0)
    logical_addr_width = max(1, int(math.ceil(math.log(max(1, int(OPTS.num_words)), 2))))
    physical_addr_width = max(logical_addr_width, int(sram_obj.addr_size))
    has_spare_cols = physical_data_width > logical_data_width

    stub_dir = os.path.join(PROJECT_DIR, "src", "rtl", "util")
    os.makedirs(stub_dir, exist_ok=True)
    stub_path = os.path.join(stub_dir, "{}_stub.v".format(OPTS.output_name))

    logical_addr = zero_extend_signal("addr0", logical_addr_width, physical_addr_width)
    logical_din = zero_extend_signal("din0", logical_data_width, physical_data_width)

    with open(stub_path, "w") as stub:
        stub.write("// Auto-generated by sram/sram_compiler.py.\n")
        stub.write("// Logical wrapper for OpenRAM macro {}.\n\n".format(OPTS.output_name))

        stub.write("(* blackbox *)\n")
        stub.write("module {}(\n".format(OPTS.output_name))
        stub.write("`ifdef USE_POWER_PINS\n")
        stub.write("  inout vccd1,\n")
        stub.write("  inout vssd1,\n")
        stub.write("`endif\n")
        stub.write("  input clk0,\n")
        stub.write("  input csb0,\n")
        stub.write("  input web0,\n")
        if has_spare_cols:
            stub.write("  input spare_wen0,\n")
        stub.write("  input{} addr0,\n".format(verilog_range(physical_addr_width)))
        stub.write("  input{} din0,\n".format(verilog_range(physical_data_width)))
        stub.write("  output{} dout0\n".format(verilog_range(physical_data_width)))
        stub.write(");\n")
        stub.write("endmodule\n\n")

        stub.write("module {}_stub(\n".format(OPTS.output_name))
        stub.write("`ifdef USE_POWER_PINS\n")
        stub.write("  inout vccd1,\n")
        stub.write("  inout vssd1,\n")
        stub.write("`endif\n")
        stub.write("  input clk0,\n")
        stub.write("  input csb0,\n")
        stub.write("  input web0,\n")
        stub.write("  input{} addr0,\n".format(verilog_range(logical_addr_width)))
        stub.write("  input{} din0,\n".format(verilog_range(logical_data_width)))
        stub.write("  output{} dout0\n".format(verilog_range(logical_data_width)))
        stub.write(");\n\n")
        stub.write("  wire{} macro_dout0;\n\n".format(verilog_range(physical_data_width)))
        stub.write("  assign dout0 = macro_dout0{};\n\n".format(
            "[{}:0]".format(logical_data_width - 1) if physical_data_width != logical_data_width else ""
        ))
        stub.write("  {} u_macro (\n".format(OPTS.output_name))
        stub.write("`ifdef USE_POWER_PINS\n")
        stub.write("    .vccd1(vccd1),\n")
        stub.write("    .vssd1(vssd1),\n")
        stub.write("`endif\n")
        stub.write("    .clk0(clk0),\n")
        stub.write("    .csb0(csb0),\n")
        stub.write("    .web0(web0),\n")
        if has_spare_cols:
            stub.write("    .spare_wen0(1'b0),\n")
        stub.write("    .addr0({}),\n".format(logical_addr))
        stub.write("    .din0({}),\n".format(logical_din))
        stub.write("    .dout0(macro_dout0)\n")
        stub.write("  );\n")
        stub.write("endmodule\n")

    debug.print_raw("SRAM stub file is: {}".format(stub_path))

write_sram_stub(s)

# Delete temp files etc.
openram.end_openram()
openram.print_time("End", datetime.datetime.now(), start_time)
