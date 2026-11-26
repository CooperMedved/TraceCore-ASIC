# Logical synthesis for TraceCore.
# Run: dc_shell -f scripts/synth.tcl

proc find_named_db {directory filename} {
    set matches {}

    foreach path [glob -nocomplain -directory $directory *] {
        if {[file isdirectory $path] && [file type $path] ne "link"} {
            set matches [concat $matches \
                [find_named_db $path $filename]]
        } elseif {[file isfile $path] &&
                  [file tail $path] eq $filename} {
            lappend matches [file normalize $path]
        }
    }

    return $matches
}

proc synth_tracecore {} {
    set root [file normalize \
        [file join [file dirname [info script]] ..]]

    set top tracecore_top

    # Use an explicit library override if provided.
    # Otherwise locate the compiled version of the SAED14 TT library.
    if {[info exists ::env(SAED14_DB)] &&
        $::env(SAED14_DB) ne ""} {
        set db [file normalize $::env(SAED14_DB)]
    } else {
        set lib_root [file normalize ~/eda-libs/saed14]

        set matches [find_named_db \
            $lib_root saed14rvt_tt0p8v25c.db]

        if {[llength $matches] != 1} {
            error "Expected one saed14rvt_tt0p8v25c.db under $lib_root. Found: $matches. Set SAED14_DB to your compiled .db."
        }

        set db [lindex $matches 0]
    }

    if {![file readable $db] ||
        [file extension $db] ne ".db"} {
        error "Unreadable or invalid target .db: $db"
    }

    # Each run gets its own output directory.
    set run_name \
        "[clock format [clock seconds] -format %Y%m%d_%H%M%S]_[pid]"

    set run     [file join $root build synth $run_name]
    set reports [file join $run reports]
    set outputs [file join $run outputs]

    file mkdir $reports $outputs [file join $run WORK]

    puts "RUN DIRECTORY: $run"
    puts "TARGET LIBRARY: $db"

    # Library setup
    set_app_var search_path [concat \
        [list [file join $root rtl] [file dirname $db]] \
        [get_app_var search_path]]

    set_app_var target_library [list $db]
    set_app_var synthetic_library [list dw_foundation.sldb]

    set_app_var link_library [concat \
        [list * $db] [get_app_var synthetic_library]]

    define_design_lib WORK -path [file join $run WORK]

    set_svf [file join $outputs ${top}.svf]

    # RTL sources
    set sources {}

    foreach name {
        spi_monitor
        uart_monitor
        capture_controller
        capture_buffer
        uart_tx
        capture_readout
        tracecore_top
    } {
        set path [file join $root rtl ${name}.v]

        if {![file readable $path]} {
            error "Missing RTL file: $path"
        }

        lappend sources $path
    }

    if {![analyze -format verilog $sources]} {
        error "RTL analysis failed"
    }

    elaborate $top -parameters \
        "CLK_FREQ_HZ=100000000,MONITOR_BAUD_RATE=115200,OUTPUT_BAUD_RATE=115200,ADDR_WIDTH=10"

    current_design $top

    if {![link]} {
        error "Link failed; inspect missing library references"
    }

    uniquify

    redirect -file [file join $reports pre_check_design.rpt] {
        check_design
    }

    redirect -file [file join $reports units.rpt] {
        report_units
    }

    # Timing values assume ns in the SAED14 library.
    # Internal clock: 100 MHz.
    create_clock -name FUNC_CLK -period 10.000 [get_ports clk]

    set_clock_uncertainty -setup 0.100 [get_clocks FUNC_CLK]
    set_clock_uncertainty -hold  0.050 [get_clocks FUNC_CLK]
    set_clock_transition 0.050 [get_clocks FUNC_CLK]

    # Initial interface budgets.
    # Replace these with actual system timing when available.
    set async_ports [get_ports {
        spi_sclk spi_cs_n spi_mosi spi_miso uart_rx
    }]

    set data_inputs [remove_from_collection \
        [all_inputs] [get_ports clk]]

    set sync_inputs [remove_from_collection \
        $data_inputs $async_ports]

    # Synchronous controls include rst.
    # Do not false-path the synchronous reset.
    set_input_delay -clock FUNC_CLK -max 2.000 $sync_inputs
    set_input_delay -clock FUNC_CLK -min 0.200 $sync_inputs

    set_input_transition 0.100 $data_inputs

    set_output_delay -clock FUNC_CLK -max  2.000 [all_outputs]
    set_output_delay -clock FUNC_CLK -min -0.200 [all_outputs]

    # Load is in the target library's capacitance units.
    set_load 0.020 [all_outputs]

    # Asynchronous input delays are bookkeeping values.
    # Only the external input -> first synchronizer D path is exempt.
    set_input_delay -clock FUNC_CLK -max 0.000 $async_ports
    set_input_delay -clock FUNC_CLK -min 0.000 $async_ports

    foreach {port first_d} {
        spi_sclk u_spi_monitor/sclk_meta_reg/D
        spi_cs_n u_spi_monitor/cs_n_meta_reg/D
        spi_mosi u_spi_monitor/mosi_meta_reg/D
        spi_miso u_spi_monitor/miso_meta_reg/D
        uart_rx  u_uart_monitor/rx_meta_reg/D
    } {
        set endpoint [get_pins -quiet $first_d]

        if {[sizeof_collection $endpoint] != 1} {
            error "Expected first-stage pin missing: $first_d. Inspect elaborated register names before changing the exception."
        }

        set_false_path -from [get_ports $port] -to $endpoint
    }

    # Synchronizer first-stage Q -> second-stage D remains timed.
    set_fix_multiple_port_nets -all -buffer_constants

    redirect -file [file join $reports pre_check_timing.rpt] {
        check_timing
    }

    # Preserve hierarchy; do not enable retiming.
    # Report pre-CTS hold timing without forcing hold buffering.
    if {![compile_ultra -no_autoungroup -no_boundary_optimization]} {
        error "compile_ultra failed; inspect the synthesis log"
    }

    change_names -rules verilog -hierarchy

    # Design and timing reports
    redirect -file [file join $reports check_design.rpt] {
        check_design
    }

    redirect -file [file join $reports check_timing.rpt] {
        check_timing
    }

    redirect -file [file join $reports qor.rpt] {
        report_qor
    }

    redirect -file [file join $reports area.rpt] {
        report_area -hierarchy
    }

    redirect -file [file join $reports resources.rpt] {
        report_resources -hierarchy
    }

    redirect -file [file join $reports references.rpt] {
        report_reference -hierarchy
    }

    redirect -file [file join $reports design.rpt] {
        report_design
    }

    # All reported constraint violators.
    redirect -file [file join $reports violations.rpt] {
        report_constraint -all_violators -verbose
    }

    # Detailed worst setup and hold paths.
    redirect -file [file join $reports setup.rpt] {
        report_timing \
            -delay_type max \
            -max_paths 100 \
            -nworst 1 \
            -input_pins \
            -nets \
            -transition_time \
            -capacitance
    }

    redirect -file [file join $reports hold.rpt] {
        report_timing \
            -delay_type min \
            -max_paths 100 \
            -nworst 1 \
            -input_pins \
            -nets \
            -transition_time \
            -capacitance
    }

    # Save mapped design and constraints.
    write -format ddc -hierarchy \
        -output [file join $outputs ${top}.ddc]

    write -format verilog -hierarchy \
        -output [file join $outputs ${top}_mapped.v]

    write_sdc [file join $outputs ${top}.sdc]

    set_svf -off

    puts "SYNTHESIS FINISHED: $run"
    puts "Review check_timing.rpt, violations.rpt, setup.rpt, and hold.rpt."
    puts "Completion does not imply timing closure."
}

if {[catch {synth_tracecore} reason]} {
    puts stderr "SYNTHESIS FAILED: $reason"
    exit 1
}

exit 0