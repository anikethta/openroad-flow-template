# OpenROAD Flow Template [^1]

This repository is a small, standalone RTL-to-GDSII template using:

- Yosys for RTL synthesis
- OpenROAD for place-and-route
- SkyWater SKY130 HD standard cells from `~/pdks/skywater-pdk`

The default design is `top`, built from RTL in `src/rtl`, constrained by
`src/constraints.sdc`, synthesized into `build/synth`, then placed and routed
into `build/pnr`.

## Directory Layout

```text
.
├── scripts/
│   ├── synth.tcl          # Yosys synthesis flow
│   ├── pnr.tcl            # OpenROAD place-and-route flow
│   └── rtlmp.tcl          # Optional RTLMP helper proc
├── sram/
│   ├── config/            # OpenRAM SRAM config files
│   └── sram_compiler.py   # Batch SRAM generation wrapper
├── src/
│   ├── constraints.sdc    # Timing constraints for synthesis/PnR
│   └── rtl/
│       ├── top.sv         # Default top-level RTL
│       ├── fifo.sv        # Example design logic
│       └── util/          # Generated SRAM blackbox/wrapper stubs
└── build/                 # Generated outputs, usually gitignored
    ├── sram/              # OpenRAM-generated SRAM collateral
    ├── synth/
    │   ├── top_synth.v
    │   ├── top.json
    │   └── reports/
    └── pnr/
        ├── top.def
        ├── top.odb
        ├── top.routed.v
        └── reports/
```

## Environment

Load the OSS CAD Suite environment before running the flow:

```sh
source ~/oss-cad-suite/environment
```

The scripts assume the SkyWater PDK is available here:

```text
~/pdks/skywater-pdk
```

For a different install location, update `pdk_root` in `scripts/pnr.tcl`, or set
`PDK_ROOT` for synthesis.

OpenRAM's Sky130 technology setup is stricter than the PnR scripts: it expects
an `open_pdks` install containing `sky130A`, such as:

```text
$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc
$PDK_ROOT/sky130A/libs.tech/ngspice/sky130.lib.spice
```

Use the OpenRAM source environment rather than an unrelated pip package:

```sh
export OPENRAM_HOME=$HOME/OpenRAM/compiler
export OPENRAM_TECH=$HOME/OpenRAM/technology
export PYTHONPATH=$HOME/OpenRAM
export PDK_ROOT=$HOME/pdks/share/pdk   # directory that directly contains sky130A
```

If `sky130A` is directly under `~/pdks`, use `export PDK_ROOT=$HOME/pdks`.

## SRAM Generation

SRAMs are generated with OpenRAM using config files in:

```text
sram/config/
```

Run the SRAM compiler wrapper from the project root:

```sh
python3 sram/sram_compiler.py
```

With no config argument, the wrapper loops through every `*.py` file in
`sram/config`. You can also generate one config or a different config directory:

```sh
python3 sram/sram_compiler.py sram/config/example_config.py
python3 sram/sram_compiler.py path/to/configs
```

The wrapper clears `build/sram/` once before a top-level run, then writes all
generated SRAM collateral there:

```text
build/sram/sram_256x8.lef
build/sram/sram_256x8.gds
build/sram/sram_256x8.v
build/sram/sram_256x8_TT_1p8V_25C.lib
```

It also writes a synthesis-facing blackbox/wrapper stub into:

```text
src/rtl/util/sram_256x8_stub.v
```

The generated OpenRAM Verilog model is for simulation/collateral. Synthesis uses
the stub: the wrapper exposes logical-width ports, ties off spare/extra bits,
and instantiates the real blackbox macro cell, for example `sram_256x8`.

## Synthesis

Run Yosys from the project root:

```sh
yosys -c scripts/synth.tcl
```

The synthesis script:

- reads SystemVerilog/Verilog from `src/rtl` and one-level utility subdirs
- uses `top` as the default top module
- maps logic to SKY130 HD using the nominal liberty file
- maps raw constants to `sky130_fd_sc_hd__conb_1` tie cells
- writes a synthesized Verilog netlist and JSON netlist
- writes stat, stdcell area, macro area, and timing reports

Default synthesis outputs:

```text
build/synth/top_synth.v
build/synth/top.json
build/synth/reports/rtl_stat.rpt
build/synth/reports/synth_stat.rpt
build/synth/reports/area.rpt
build/synth/reports/stdcell_area.rpt
build/synth/reports/macro_area.rpt
build/synth/reports/timing.rpt
```

Useful overrides:

```sh
TOP=my_top yosys -c scripts/synth.tcl
CLOCK_PERIOD_PS=10000 yosys -c scripts/synth.tcl
LIBERTY=/path/to/corner.lib yosys -c scripts/synth.tcl
SYNTH_FLATTEN=1 yosys -c scripts/synth.tcl
SRAM_LIBERTY=build/sram/sram_256x8_TT_1p8V_25C.lib yosys -c scripts/synth.tcl
```

`CLOCK_PERIOD_PS` is passed to ABC in picoseconds. For example, `5000` means a
5 ns clock target.

Hierarchy is preserved by default so OpenROAD RTLMP has useful module boundaries
to cluster. Set `SYNTH_FLATTEN=1` when you want the older flat netlist style.

Macro Liberty files are not used for ABC standard-cell mapping. They are used to
produce `macro_area.rpt`, which counts macro instances in `top_synth.v` and
multiplies by the macro area from Liberty. Use this alongside
`stdcell_area.rpt`.

If a macro blackbox disappears from `top_synth.v`, make sure at least one macro
output is observable or functionally used. The example design exposes
`sram_test_dout[7:0]` at top level so the SRAM test macro is retained.

## Timing Constraints

The main SDC file is:

```text
src/constraints.sdc
```

For a new design, update:

- `create_clock` for the real clock port and period
- `set_input_delay` for all input ports
- `set_output_delay` for all output ports
- clock uncertainty and transition values as needed

Keep the SDC simple and OpenROAD-compatible. Some commercial-tool SDC commands,
such as `remove_from_collection`, are not supported by OpenSTA/OpenROAD.

## Place and Route

Run OpenROAD from the project root:

```sh
openroad scripts/pnr.tcl
```

The PnR script reads:

```text
build/synth/top_synth.v
src/constraints.sdc
~/pdks/skywater-pdk/libraries/sky130_fd_sc_hd/latest
build/sram/*.lef
build/sram/*_TT_1p8V_25C.lib
```

Default final outputs:

```text
build/pnr/top.odb
build/pnr/top.def
build/pnr/top.routed.v
build/pnr/top.sdc
build/pnr/reports/
```

## PnR Bring-Up Stages

Use `flow_stop_after` in `scripts/pnr.tcl` to stop after a stage:

```tcl
set flow_stop_after "floorplan"
```

Supported stages:

```text
link
rtlmp
floorplan
place
cts
route
finish
```

Recommended bring-up order for a new design:

1. `link`: confirm Liberty, LEF, netlist, and SDC load correctly.
2. `rtlmp`: inspect RTLMP clustering/checkpoints before tapcell and PDN.
3. `floorplan`: confirm die/core area, rows, tracks, tapcells, PDN, and pins.
4. `place`: confirm global/detailed placement succeeds.
5. `cts`: confirm clock tree synthesis and timing repair.
6. `route`: confirm global/detailed route and antenna repair.
7. `finish`: write final DEF/ODB/netlist/SDC and reports.

## Things to Tweak in the PnR Script

Most project-specific settings are near the top of `scripts/pnr.tcl`.

Design setup:

```tcl
set design_name "top"
set top_module  "top"
set netlist     [file join $project_dir build synth top_synth.v]
set sdc_file    [file join $project_dir src constraints.sdc]
```

Floorplan:

```tcl
set site_name "unithd"
set die_area  {0 0 700 500}
set core_area {40 40 660 460}
```

RTLMP:

```tcl
set run_rtlmp            0
set rtlmp_keep_data      1
set rtlmp_target_util    0.25
set rtlmp_max_num_level  2
set rtlmp_fence          {380 80 640 300}
```

RTLMP is for hierarchy-guided standard-cell clustering and physical planning. It
does not create a black-box macro, and it does not require a separate macro
Liberty/LEF/GDS view. The `run_rtlmp` toggle remains in `scripts/pnr.tcl`, while
the `run_rtlmp` proc itself lives in `scripts/rtlmp.tcl`.

`rtlmp_fence` is ignored when `run_rtlmp` is `0`. Placement regions are separate
and still apply unless you clear them:

```tcl
set placement_regions [list]
```

SRAM macro placement:

```tcl
set sram_macro_inst    "fifo_inst/sram_storage/u_macro"
set sram_macro_origin  {60.0 80.0}
set sram_macro_orient  R0
set sram_macro_status  FIRM
```

Override the macro location from the shell:

```sh
SRAM_MACRO_ORIGIN="{80 120}" openroad scripts/pnr.tcl
```

The default macro instance is the hard SRAM inside the generated wrapper:

```text
fifo_inst/sram_storage/u_macro
```

Routing and pins:

```tcl
set signal_layers  "met1-met5"
set clock_layers   "met3-met5"
set route_layer    "met3"
set pin_hor_layers "met3"
set pin_ver_layers "met2"
```

Pin placement groups:

```tcl
set pin_constraints [list \
  [dict create region "left:*"  pins {din* rst wr_en rd_en}] \
  [dict create region "right:*" pins {dout* sram_test_dout* full empty}] \
  [dict create region "top:*"   pins {clk}] \
]
```

For a new design, this is one of the first things to update.

## SKY130 Notes

The PnR script intentionally handles a few SKY130 LEF quirks:

- It uses `sky130_fd_sc_hd.tlef` as the technology LEF.
- It skips some problematic standard-cell LEF views.
- It explicitly loads `tapvpwrvgnd_1.magic.lef` for tapcells.
- It explicitly loads `diode_2.magic.lef` because that view has nonzero
  `ANTENNADIFFAREA`, which OpenROAD needs for antenna repair.
- It creates routing tracks with `make_tracks` because the raw PDK LEF setup may
  not provide the track structures OpenROAD expects.

The inline PDN is a minimal SKY130 HD-style grid:

- met1 followpins
- met4 horizontal/vertical stripe layer use through PDN commands
- met5 stripe layer use
- met1-met4 and met4-met5 PDN connections

For serious tapeout-oriented work, replace or validate this PDN against a known
platform configuration.

## SRAM Macro Integration

The example flow integrates an OpenRAM SRAM as a hard macro.

Synthesis sees the generated stub in `src/rtl/util`, but PnR uses the real macro
views:

```text
build/sram/sram_256x8.lef
build/sram/sram_256x8_TT_1p8V_25C.lib
```

`scripts/pnr.tcl` auto-discovers those views:

```tcl
set macro_lefs      [lsort [glob -nocomplain [file join $sram_dir "*.lef"]]]
set macro_liberties [lsort [glob -nocomplain [file join $sram_dir "*_TT_1p8V_25C.lib"]]]
```

OpenRAM emits macro LEFs with `DATABASE MICRONS 2000`, while the SKY130 HD tech
LEF uses `DATABASE MICRONS 1000`. The PnR script leaves the original OpenRAM LEF
untouched, copies it into `build/pnr/macro_lefs/`, rewrites the DBU header to
1000, and reads that normalized copy.

The default SRAM macro is fixed before tapcell/PDN:

```def
fifo_inst/sram_storage/u_macro sram_256x8
```

To verify placement after PnR:

```sh
rg "fifo_inst/sram_storage/u_macro|sram_256x8" build/pnr/top.routed.def
rg "sram_256x8" build/pnr/top.routed.v
```

Expected DEF shape:

```def
- fifo_inst/sram_storage/u_macro sram_256x8 + FIXED ( 60000 80000 ) N ;
```

The coordinates are DBU. With `UNITS DISTANCE MICRONS 1000`, this means:

```text
x = 60 um
y = 80 um
```

The generated `sram_256x8.lef` macro is about `298.035um x 188.73um`, so the
default floorplan is larger than the earlier tiny example floorplan.

Important: the OpenROAD GUI/DEF view shows the SRAM as a LEF abstract block. It
does not show the SRAM's internal bitcell layout. To view SRAM internals, open
the SRAM GDS directly in KLayout:

```sh
/Applications/KLayout/klayout.app/Contents/MacOS/klayout build/sram/sram_256x8.gds
```

If `klayout` is not on your shell `PATH`, use the full app path above or:

```sh
open -a KLayout build/sram/sram_256x8.gds
```

This OpenROAD build does not provide `write_gds`, so full-chip GDS streaming is
left to KLayout/Magic-based DEF-to-GDS tooling. The current template focuses on
DEF/ODB/routed-Verilog PnR outputs plus direct SRAM GDS inspection.

## Reports

Synthesis reports:

```text
build/synth/reports/
```

PnR reports:

```text
build/pnr/reports/
```

The PnR script writes reports for worst slack, TNS, design checks, setup paths,
hold paths, and route DRC.

## Common Issues

`clk toplevel port is not placed`

Top-level IO pins must be placed before global placement. This flow places pins
during the floorplan stage before `global_placement`.

`Missing track structure for layer li1`

The raw LEFs did not provide routing tracks. This flow calls `make_sky130_tracks`
after floorplan initialization.

`No PDN setup found`

OpenROAD needs PDN commands before `pdngen`. This flow provides an inline PDN
block via `pdn_inline_script`.

`Diode ... ANTENNADIFFAREA is zero`

OpenROAD loaded a diode LEF view without antenna diffusion data. This flow
explicitly loads `sky130_fd_sc_hd__diode_2.magic.lef`.

SDC command errors

OpenROAD uses OpenSTA, so not every commercial SDC/Tcl helper is available. Keep
constraints simple and prefer direct `get_ports`/`get_clocks` expressions.

`Unable to find open_pdks tech file. Set PDK_ROOT.`

OpenRAM's Sky130 tech plugin needs an `open_pdks` install with `sky130A`, not
just the raw `skywater-pdk` tree used by PnR. Set `PDK_ROOT` to the directory
that directly contains `sky130A`.

`LEF UNITS DATABASE MICRON convert factor ... is greater than the database units`

OpenRAM SRAM LEFs may use `DATABASE MICRONS 2000`, while the SKY130 tech LEF
uses 1000. `scripts/pnr.tcl` normalizes macro LEFs into
`build/pnr/macro_lefs/` before `read_lef`.

`Net ... of signal type GROUND is not routable by TritonRoute`

Raw constants feeding macro pins can become special ground/power-typed nets.
The synthesis flow runs `hilomap` to map constants to
`sky130_fd_sc_hd__conb_1` tie cells. Rerun synthesis before rerunning PnR after
changing this behavior.

SRAM is hard to see in OpenROAD GUI

The OpenROAD GUI shows the SRAM LEF abstract, not the internal GDS geometry.
Check `top.routed.def` for the fixed macro component and use KLayout to inspect
`build/sram/sram_256x8.gds` if you want to see the actual SRAM layout.

## Adapting This Template

For a new project:

1. Put RTL in `src/rtl`.
2. Add OpenRAM SRAM configs under `sram/config` if the design uses hard SRAMs.
3. Run `python3 sram/sram_compiler.py` to generate `build/sram` collateral and
   RTL stubs.
4. Update `top_module` in both scripts, or run synthesis with `TOP=...`.
5. Update `src/constraints.sdc`.
6. Run synthesis and inspect `build/synth/reports`.
7. Update PnR floorplan dimensions, macro placement, placement regions, and pin
   constraints.
8. Bring up OpenROAD stage by stage using `flow_stop_after`.
9. Once each stage is clean, set `flow_stop_after` to `finish`.

[^1]: this readme is mad agentic icl
