`timescale 1ns/1ps

module tb_capture_readout;

    parameter integer ADDR_WIDTH = 10;

    localparam integer DEPTH = (1 << ADDR_WIDTH);
    localparam real BIT_NS = 200.0;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst          = 1'b1;
    reg start        = 1'b0;
    reg clear        = 1'b0;
    reg write_enable = 1'b0;
    reg [63:0] write_record = 64'd0;

    wire [ADDR_WIDTH:0] record_count;
    wire [ADDR_WIDTH-1:0] read_address;
    wire [63:0] read_record;
    wire read_valid;
    wire full;
    wire empty;

    reg stall        = 1'b0;
    reg invalid_read = 1'b0;

    wire tx_start;
    wire tx_busy;
    wire tx_done;
    wire [7:0] tx_data;
    wire serial_tx;

    wire busy;
    wire done;
    wire error;

    integer completions = 0;
    integer errors      = 0;
    integer launches    = 0;
    integer saved_launches;
    integer saved_completions;

    reg prev_done  = 1'b0;
    reg prev_error = 1'b0;

    capture_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) buffer_dut (
        .clk         (clk),
        .rst         (rst),
        .clear       (clear),
        .write_enable(write_enable),
        .write_record(write_record),
        .read_address(read_address),
        .read_record (read_record),
        .read_valid  (read_valid),
        .full        (full),
        .empty       (empty),
        .record_count(record_count)
    );

    capture_readout #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .record_count(record_count),
        .read_address(read_address),
        .read_record (read_record),
        .read_valid  (read_valid && !invalid_read),
        .tx_busy     (tx_busy || stall),
        .tx_done     (tx_done),
        .tx_start    (tx_start),
        .tx_data     (tx_data),
        .busy        (busy),
        .done        (done),
        .error       (error)
    );

    uart_tx #(
        .CLK_FREQ_HZ(100_000_000),
        .BAUD_RATE  (5_000_000)
    ) transmitter (
        .clk    (clk),
        .rst    (rst),
        .start  (tx_start),
        .data_in(tx_data),
        .tx     (serial_tx),
        .busy   (tx_busy),
        .done   (tx_done)
    );

    `include "serial_checks.vh"

    function [63:0] pattern;
        input integer index;

        begin
            pattern = 64'h1234_ABCD_9876_0000 + index;
        end
    endfunction

    always @(posedge clk) begin
        if (!rst && tx_start && !tx_busy)
            launches = launches + 1;
    end

    always @(negedge clk) begin
        if (!rst) begin
            if (done && prev_done)
                $fatal(1, "done pulse too long");

            if (error && prev_error)
                $fatal(1, "error pulse too long");

            if (done)
                completions = completions + 1;

            if (error)
                errors = errors + 1;

            prev_done  = done;
            prev_error = error;
        end
    end

    task pulse_start;
        begin
            @(negedge clk);
            #1;
            start = 1'b1;

            @(negedge clk);
            #1;
            start = 1'b0;
        end
    endtask

    task clear_buffer;
        begin
            @(negedge clk);
            #1;
            clear = 1'b1;

            @(negedge clk);
            #1;
            clear = 1'b0;
        end
    endtask

    task populate;
        input integer count;
        integer n;

        begin
            for (n = 0; n < count; n = n + 1) begin
                @(negedge clk);
                #1;
                write_enable = 1'b1;
                write_record = pattern(n);
            end

            @(negedge clk);
            #1;
            write_enable = 1'b0;
        end
    endtask

    task check_records;
        input integer count;
        integer n;
        reg [63:0] received;

        begin
            for (n = 0; n < count; n = n + 1) begin
                receive_record(received);

                if (received !== pattern(n))
                    $fatal(1,
                        "Record %0d: got %h expected %h",
                        n, received, pattern(n));
            end
        end
    endtask

    task finish_readout;
        begin
            wait (done === 1'b1);

            @(negedge clk);
            #1;

            if (busy !== 1'b0 || tx_busy !== 1'b0)
                $fatal(1, "Premature completion");
        end
    endtask

    initial begin
        if ($test$plusargs("waves")) begin
            $dumpfile("build/capture_readout.vcd");
            $dumpvars(0, tb_capture_readout);
        end

        repeat (4) @(negedge clk);
        #1;
        rst = 1'b0;

        // Empty-buffer readout.
        pulse_start;
        #1;

        if (completions != 1 || launches != 0 || busy !== 1'b0)
            $fatal(1, "Empty readout failed");

        $display("PASS: Empty readout");

        // Two records, with initial transmitter backpressure.
        populate(2);
        stall = 1'b1;

        pulse_start;

        repeat (8) @(negedge clk);
        #1;

        if (tx_start !== 1'b0 || busy !== 1'b1 || launches != 0)
            $fatal(1, "Transmitter backpressure failed");

        fork
            check_records(2);

            begin
                @(negedge clk);
                #1;
                stall = 1'b0;

                // A start while active must not restart readout.
                repeat (8) @(negedge clk);
                pulse_start;
            end
        join

        finish_readout;

        if (completions != 2 || launches != 16 || errors != 0)
            $fatal(1, "Two-record count mismatch");

        $display("PASS: Byte order, backpressure, busy start ignored");

        // Exercise the complete address range.
        clear_buffer;
        populate(DEPTH);

        if (full !== 1'b1)
            $fatal(1, "Buffer not full");

        saved_launches = launches;

        fork
            check_records(DEPTH);
            pulse_start;
        join

        finish_readout;

        if (launches - saved_launches != DEPTH * 8)
            $fatal(1, "Full-buffer transmit length incorrect");

        if (record_count !== DEPTH)
            $fatal(1, "Readout modified buffer");

        $display("PASS: Full %0d-record address range", DEPTH);

        // Invalid buffer read must abort.
        invalid_read = 1'b1;
        saved_launches    = launches;
        saved_completions = completions;

        pulse_start;

        wait (error === 1'b1);

        @(negedge clk);
        #1;

        if (errors != 1 ||
            busy !== 1'b0 ||
            launches != saved_launches ||
            completions != saved_completions)
            $fatal(1, "Invalid-read abort failed");

        invalid_read = 1'b0;

        $display("PASS: Invalid read abort");

        // Reset during an active UART byte.
        pulse_start;

        wait (tx_busy === 1'b1);

        @(negedge clk);
        #1;
        rst = 1'b1;

        repeat (2) @(negedge clk);
        #1;

        if (busy !== 1'b0 ||
            tx_start !== 1'b0 ||
            serial_tx !== 1'b1 ||
            done !== 1'b0 ||
            error !== 1'b0)
            $fatal(1, "Reset during readout failed");

        rst = 1'b0;

        repeat (4) @(negedge clk);
        #1;

        if (busy !== 1'b0 || tx_busy !== 1'b0)
            $fatal(1, "Reset recovery failed");

        $display("PASS: Readout reset abort");
        $display("PASS: All capture_readout checks completed.");

        $finish;
    end

    initial begin
        #100_000_000;
        $fatal(1, "Readout test timeout");
    end

endmodule