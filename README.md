# TraceCore — SPI/UART Protocol Analyzer

A digital protocol analyzer developed in Verilog, targeting FPGA
demonstration and a Synopsys ASIC implementation flow.

## Planned features

- SPI mode 0 monitoring: 8-bit transfers, MOSI and MISO
- UART monitoring: 8N1 with configurable baud divider
- Selectable SPI or UART capture
- Immediate and byte-match triggers
- Timestamped capture records
- 16-record capture buffer
- Dedicated UART transmitter for PC readout

## Planned ASIC flow

RTL verification → synthesis → scan insertion → ATPG →
pattern simulation → physical implementation → post-route timing

## Project structure

- rtl/         Verilog design modules
- tb/          Testbenches
- scripts/     Simulation and EDA scripts
- constraints/ Timing constraints
- docs/        Architecture and results

## Status

Architecture and initial RTL development.
