# OpenROAD Flow Template

This repository is a small, standalone RTL-to-layout template using:

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
│   └── pnr.tcl            # OpenROAD place-and-route flow
├── src/
│   ├── constraints.sdc    # Timing constraints for synthesis/PnR
│   └── rtl/
│       ├── top.sv         # Default top-level RTL
│       └── fifo.sv        # Example design logic
└── build/                 # Generated outputs, usually gitignored
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

## Synthesis

Run Yosys from the project root:

```sh
yosys -c scripts/synth.tcl
```

The synthesis script:

- reads SystemVerilog/Verilog from `src/rtl`
- uses `top` as the default top module
- maps logic to SKY130 HD using the nominal liberty file
- writes a synthesized Verilog netlist and JSON netlist
- writes area, timing, and stat reports

Default synthesis outputs:

```text
build/synth/top_synth.v
build/synth/top.json
build/synth/reports/rtl_stat.rpt
build/synth/reports/synth_stat.rpt
build/synth/reports/area.rpt
build/synth/reports/timing.rpt
```

Useful overrides:

```sh
TOP=my_top yosys -c scripts/synth.tcl
CLOCK_PERIOD_PS=10000 yosys -c scripts/synth.tcl
LIBERTY=/path/to/corner.lib yosys -c scripts/synth.tcl
```

`CLOCK_PERIOD_PS` is passed to ABC in picoseconds. For example, `5000` means a
5 ns clock target.

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
floorplan
place
cts
route
finish
```

Recommended bring-up order for a new design:

1. `link`: confirm Liberty, LEF, netlist, and SDC load correctly.
2. `floorplan`: confirm die/core area, rows, tracks, tapcells, PDN, and pins.
3. `place`: confirm global/detailed placement succeeds.
4. `cts`: confirm clock tree synthesis and timing repair.
5. `route`: confirm global/detailed route and antenna repair.
6. `finish`: write final DEF/ODB/netlist/SDC and reports.

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
set die_area  {0 0 300 300}
set core_area {20 20 280 280}
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
  [dict create region "left:*"  pins {din* rst wr_en rd_en flush}] \
  [dict create region "right:*" pins {dout* full empty}] \
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

## Macro Support

The PnR script has hooks for macro LEFs and fixed/firm macro placement:

```tcl
set macro_lefs [list /path/to/macro.lef]
lappend macro_placements [dict create \
  name "u_macro" origin {40.0 120.0} orientation R0 status FIRM]
```

If you already have a floorplan DEF with macro placement, set:

```tcl
set floorplan_def "/path/to/floorplan.def"
```

Macros should be placed before tapcell and PDN generation.

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

## Adapting This Template

For a new project:

1. Put RTL in `src/rtl`.
2. Update `top_module` in both scripts, or run synthesis with `TOP=...`.
3. Update `src/constraints.sdc`.
4. Run synthesis and inspect `build/synth/reports`.
5. Update PnR floorplan dimensions and pin constraints.
6. Bring up OpenROAD stage by stage using `flow_stop_after`.
7. Once each stage is clean, set `flow_stop_after` to `finish`.

