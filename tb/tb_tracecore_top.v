`timescale 1ns/1ps

module tb_tracecore_top;

    parameter integer ADDR_WIDTH = 10;

    localparam integer DEPTH = (1 << ADDR_WIDTH);

    // Faster baud rates shorten simulation.
    localparam real BIT_NS       = 200.0;
    localparam real INPUT_BIT_NS = 1000.0;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst           = 1'b1;
    reg arm           = 1'b0;
    reg stop          = 1'b0;
    reg readout_start = 1'b0;

    reg protocol_select = 1'b0;
    reg trigger_enable  = 1'b0;
    reg [7:0] trigger_byte = 8'd0;

    reg spi_sclk = 1'b0;
    reg spi_cs_n = 1'b1;
    reg spi_mosi = 1'b0;
    reg spi_miso = 1'b0;
    reg uart_rx  = 1'b1;

    wire serial_tx;
    wire capture_busy;
    wire capture_done;
    wire readout_busy;
    wire readout_done;
    wire readout_error;
    wire buffer_full;
    wire buffer_empty;
    wire [ADDR_WIDTH:0] record_count;

    reg [31:0] expected_payload [0:DEPTH-1];

    integer capture_completions = 0;
    integer readout_completions = 0;
    integer i;

    reg previous_capture_done = 1'b0;
    reg previous_readout_done = 1'b0;

    tracecore_top #(
        .CLK_FREQ_HZ      (100_000_000),
        .MONITOR_BAUD_RATE(1_000_000),
        .OUTPUT_BAUD_RATE (5_000_000),
        .ADDR_WIDTH      (ADDR_WIDTH)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .arm            (arm),
        .stop           (stop),
        .readout_start  (readout_start),
        .protocol_select(protocol_select),
        .trigger_enable (trigger_enable),
        .trigger_byte   (trigger_byte),
        .spi_sclk       (spi_sclk),
        .spi_cs_n       (spi_cs_n),
        .spi_mosi       (spi_mosi),
        .spi_miso       (spi_miso),
        .uart_rx        (uart_rx),
        .uart_tx_out    (serial_tx),
        .capture_busy   (capture_busy),
        .capture_done   (capture_done),
        .readout_busy   (readout_busy),
        .readout_done   (readout_done),
        .readout_error  (readout_error),
        .buffer_full    (buffer_full),
        .buffer_empty   (buffer_empty),
        .record_count   (record_count)
    );

    `include "serial_checks.vh"

    always @(negedge clk) begin
        if (!rst) begin
            if (capture_busy && readout_busy)
                $fatal(1, "Capture/readout overlap");

            if (readout_error !== 1'b0)
                $fatal(1, "Unexpected readout error");

            if (capture_done && previous_capture_done)
                $fatal(1, "Capture done pulse too long");

            if (readout_done && previous_readout_done)
                $fatal(1, "Readout done pulse too long");

            if (capture_done)
                capture_completions = capture_completions + 1;

            if (readout_done)
                readout_completions = readout_completions + 1;

            previous_capture_done = capture_done;
            previous_readout_done = readout_done;
        end
    end

    task pulse_arm;
        begin
            @(negedge clk);
            #1;
            arm = 1'b1;

            @(negedge clk);
            #1;
            arm = 1'b0;
        end
    endtask

    task pulse_readout;
        begin
            @(negedge clk);
            #1;
            readout_start = 1'b1;

            @(negedge clk);
            #1;
            readout_start = 1'b0;
        end
    endtask

    task stop_capture;
        begin
            @(negedge clk);
            #1;
            stop = 1'b1;

            @(negedge clk);
            #1;
            stop = 1'b0;

            if (capture_busy !== 1'b0 || capture_done !== 1'b1)
                $fatal(1, "Capture did not stop");
        end
    endtask

    task spi_byte;
        input [7:0] mosi_value;
        input [7:0] miso_value;
        integer bit_number;

        begin
            for (bit_number = 7; bit_number >= 0;
                 bit_number = bit_number - 1) begin
                spi_mosi = mosi_value[bit_number];
                spi_miso = miso_value[bit_number];

                #100;
                spi_sclk = 1'b1;

                #100;
                spi_sclk = 1'b0;
            end
        end
    endtask

    task uart_frame;
        input [7:0] value;
        input bad_stop;
        integer bit_number;

        begin
            uart_rx = 1'b0;
            #(INPUT_BIT_NS);

            for (bit_number = 0; bit_number < 8;
                 bit_number = bit_number + 1) begin
                uart_rx = value[bit_number];
                #(INPUT_BIT_NS);
            end

            uart_rx = !bad_stop;
            #(INPUT_BIT_NS);

            uart_rx = 1'b1;
            #(INPUT_BIT_NS);
        end
    endtask

    task check_records;
        input integer count;
        integer n;
        reg [63:0] received;
        reg [31:0] last_timestamp;

        begin
            last_timestamp = 32'd0;

            for (n = 0; n < count; n = n + 1) begin
                receive_record(received);

                if (received[31:0] !== expected_payload[n])
                    $fatal(1,
                        "Record %0d payload %h expected %h",
                        n, received[31:0], expected_payload[n]);

                if ((^received[63:32]) === 1'bx ||
                    received[63:32] == 0)
                    $fatal(1, "Missing or unknown timestamp");

                if (n > 0 && received[63:32] <= last_timestamp)
                    $fatal(1, "Timestamps did not increase");

                last_timestamp = received[63:32];
            end
        end
    endtask

    task dump_and_check;
        input integer count;
        input inject_arm;
        integer done_before;

        begin
            done_before = readout_completions;

            fork
                check_records(count);

                begin
                    pulse_readout;

                    if (readout_busy !== 1'b1)
                        $fatal(1, "Readout not accepted");

                    if (inject_arm) begin
                        // Busy commands must not restart readout
                        // or clear the capture buffer.
                        pulse_arm;
                        pulse_readout;

                        if (capture_busy !== 1'b0 ||
                            record_count !== count)
                            $fatal(1, "Busy commands modified capture");
                    end
                end
            join

            wait (readout_done === 1'b1);

            @(negedge clk);
            #1;

            if (readout_busy !== 1'b0 ||
                record_count !== count ||
                readout_completions != done_before + 1)
                $fatal(1, "Readout completion/count mismatch");

            repeat (3) @(negedge clk);
            #1;
        end
    endtask

    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("build/tracecore_top.vcd");
            $dumpvars(0, tb_tracecore_top);
        end

        repeat (4) @(negedge clk);
        #1;
        rst = 1'b0;

        if (buffer_empty !== 1'b1 ||
            record_count !== 0 ||
            serial_tx !== 1'b1)
            $fatal(1, "Reset status failed");

        // Empty-buffer readout.
        pulse_readout;

        if (readout_completions != 1 || readout_busy !== 1'b0)
            $fatal(1, "Empty top-level readout failed");

        $display("PASS: Empty readout");

        // Simultaneous commands: arm must take priority.
        @(negedge clk);
        #1;
        arm           = 1'b1;
        readout_start = 1'b1;

        @(negedge clk);
        #1;
        arm           = 1'b0;
        readout_start = 1'b0;

        if (capture_busy !== 1'b1 || readout_busy !== 1'b0)
            $fatal(1, "Simultaneous-command priority failed");

        // Readout request during capture must be ignored.
        pulse_readout;

        if (readout_busy !== 1'b0)
            $fatal(1, "Readout started during capture");

        // Capture two SPI bytes under one chip-select.
        #100;
        spi_cs_n = 1'b0;
        #100;

        spi_byte(8'hA5, 8'h3C);
        spi_byte(8'h96, 8'hE1);

        #100;
        spi_cs_n = 1'b1;
        #200;

        if (record_count !== 2)
            $fatal(1, "SPI capture count failed");

        stop_capture;

        expected_payload[0] = 32'h0000_3CA5;
        expected_payload[1] = 32'h0000_E196;

        dump_and_check(2, 1'b1);

        // Reading must not remove records.
        dump_and_check(2, 1'b0);

        $display(
            "PASS: SPI capture, serial records, arbitration, repeated readout"
        );

        // Trigger configuration must be latched when armed.
        trigger_enable  = 1'b1;
        trigger_byte    = 8'hA5;
        protocol_select = 1'b0;

        pulse_arm;

        if (record_count !== 0)
            $fatal(1, "New arm did not clear buffer");

        // These changes must not affect the active capture.
        trigger_byte    = 8'hFF;
        protocol_select = 1'b1;
        trigger_enable  = 1'b0;

        #100;
        spi_cs_n = 1'b0;
        #100;

        spi_byte(8'h11, 8'h22);
        #100;

        if (record_count !== 0)
            $fatal(1, "Pre-trigger byte was captured");

        spi_byte(8'hA5, 8'h5A);
        spi_byte(8'hC3, 8'h3C);

        #100;
        spi_cs_n = 1'b1;
        #200;

        stop_capture;

        if (record_count !== 2)
            $fatal(1, "Trigger capture count failed");

        expected_payload[0] = 32'h0000_5AA5;
        expected_payload[1] = 32'h0000_3CC3;

        dump_and_check(2, 1'b0);

        $display("PASS: Trigger byte included; configuration latched");

        // Capture UART data and one framing error.
        protocol_select = 1'b1;
        trigger_enable  = 1'b0;

        pulse_arm;
        #1000;

        uart_frame(8'h69, 1'b0);
        uart_frame(8'hC3, 1'b0);
        uart_frame(8'h96, 1'b1);
        #200;

        if (record_count !== 3)
            $fatal(1, "UART capture count %0d", record_count);

        stop_capture;

        expected_payload[0] = 32'h0001_0069;
        expected_payload[1] = 32'h0001_00C3;
        expected_payload[2] = 32'h0101_0000;

        dump_and_check(3, 1'b0);

        $display("PASS: UART capture and framing-error record");

        // Fill the entire configured buffer.
        protocol_select = 1'b0;
        trigger_enable  = 1'b0;

        pulse_arm;

        #100;
        spi_cs_n = 1'b0;
        #100;

        for (i = 0; i < DEPTH; i = i + 1) begin
            spi_byte(i[7:0], ~i[7:0]);
            expected_payload[i] = {
                16'd0, ~i[7:0], i[7:0]
            };
        end

        #100;
        spi_cs_n = 1'b1;
        #200;

        if (buffer_full !== 1'b1 ||
            capture_busy !== 1'b0 ||
            record_count !== DEPTH)
            $fatal(1, "Automatic full-buffer stop failed");

        // Extra traffic must not overwrite captured records.
        #100;
        spi_cs_n = 1'b0;
        #100;

        spi_byte(8'hDE, 8'hAD);

        #100;
        spi_cs_n = 1'b1;
        #200;

        dump_and_check(DEPTH, 1'b0);

        $display(
            "PASS: Full %0d-record capture, automatic stop, no overwrite",
            DEPTH
        );

        // Reset while transmitting captured records.
        pulse_readout;

        wait (serial_tx === 1'b0);

        @(negedge clk);
        #1;
        rst = 1'b1;

        repeat (3) @(negedge clk);
        #1;

        if (capture_busy !== 1'b0 ||
            readout_busy !== 1'b0 ||
            serial_tx !== 1'b1 ||
            record_count !== 0 ||
            buffer_empty !== 1'b1)
            $fatal(1, "Top-level reset abort failed");

        rst = 1'b0;

        repeat (3) @(negedge clk);
        #1;

        $display("PASS: Reset aborts readout and clears buffer");
        $display("PASS: All tracecore_top checks completed.");

        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "Top-level test timeout");
    end

endmodule