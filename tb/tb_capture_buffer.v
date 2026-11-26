`timescale 1ns/1ps

module tb_capture_buffer;

    localparam integer ADDR_WIDTH = 10;
    localparam integer DEPTH = (1 << ADDR_WIDTH);

    reg clk;
    reg rst;
    reg clear;
    reg write_enable;
    reg [63:0] write_record;
    reg [ADDR_WIDTH-1:0] read_address;

    wire [63:0] read_record;
    wire read_valid;
    wire full;
    wire empty;
    wire [ADDR_WIDTH:0] record_count;

    integer i;

    capture_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
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

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Unique data pattern for every address.
    function [63:0] pattern;
        input integer index;
        begin
            pattern = 64'hA5C3_960F_1234_0000 + index;
        end
    endfunction

    // Drive inputs on falling edges.
    // Inspect results after rising-edge updates.
    task write_one;
        input [63:0] data;
        begin
            @(negedge clk);
            write_enable = 1'b1;
            write_record = data;

            @(posedge clk);
            #1;

            @(negedge clk);
            write_enable = 1'b0;
        end
    endtask

    task check_read;
        input integer address;
        input [63:0] expected;
        begin
            @(negedge clk);
            read_address = address;
            #1;

            if (read_valid !== 1'b1)
                $fatal(1, "Address %0d should be valid", address);

            if (read_record !== expected)
                $fatal(1,
                    "Address %0d: expected %h, received %h",
                    address, expected, read_record);
        end
    endtask

    task check_empty;
        begin
            if (record_count !== 0 ||
                empty !== 1'b1 ||
                full !== 1'b0)
                $fatal(1, "Incorrect empty-buffer status");

            if (read_valid !== 1'b0 ||
                read_record !== 64'd0)
                $fatal(1, "Empty buffer exposed invalid data");
        end
    endtask

    initial begin
        $dumpfile("build/capture_buffer.vcd");
        $dumpvars(0, tb_capture_buffer);

        rst          = 1'b1;
        clear        = 1'b0;
        write_enable = 1'b0;
        write_record = 64'd0;
        read_address = 0;

        repeat (3) @(posedge clk);
        #1;
        check_empty;

        @(negedge clk);
        rst = 1'b0;
        #1;
        check_empty;
        $display("PASS: Reset");

        // Write and read the first record.
        write_one(pattern(0));

        if (record_count !== 1 || empty !== 1'b0)
            $fatal(1, "First write failed");

        check_read(0, pattern(0));

        // Address 1 has not been written yet.
        @(negedge clk);
        read_address = 1;
        #1;

        if (read_valid !== 1'b0 || read_record !== 64'd0)
            $fatal(1, "Unwritten address should be invalid");

        $display("PASS: First write and invalid-address handling");

        // Fill every remaining entry.
        for (i = 1; i < DEPTH; i = i + 1) begin
            write_one(pattern(i));

            if (record_count !== (i + 1))
                $fatal(1, "Incorrect count after write %0d", i);

            if (i < DEPTH - 1 && full !== 1'b0)
                $fatal(1, "Buffer asserted full too early");
        end

        if (full !== 1'b1 ||
            empty !== 1'b0 ||
            record_count !== DEPTH)
            $fatal(1, "Incorrect full-buffer status");

        $display("PASS: Filled all %0d records", DEPTH);

        // Attempt overflow. It must not overwrite any record.
        write_one(64'hDEAD_BEEF_BAD0_CAFE);
        write_one(64'hFFFF_FFFF_FFFF_FFFF);

        if (record_count !== DEPTH || full !== 1'b1)
            $fatal(1, "Overflow changed buffer status");

        for (i = 0; i < DEPTH; i = i + 1)
            check_read(i, pattern(i));

        $display("PASS: Full readback and overflow protection");

        // Clear and write simultaneously: clear must win.
        @(negedge clk);
        clear        = 1'b1;
        write_enable = 1'b1;
        write_record = 64'hBAD0_BAD0_BAD0_BAD0;
        #1;

        if (read_valid !== 1'b0 || read_record !== 64'd0)
            $fatal(1, "Clear did not mask read output");

        @(posedge clk);
        #1;
        check_empty;

        @(negedge clk);
        clear        = 1'b0;
        write_enable = 1'b0;
        #1;
        check_empty;

        $display("PASS: Clear takes priority over write");

        // Reuse the cleared buffer.
        write_one(64'h0123_4567_89AB_CDEF);
        check_read(0, 64'h0123_4567_89AB_CDEF);

        if (record_count !== 1)
            $fatal(1, "Incorrect count after reuse");

        // Old contents beyond the new count must remain invalid.
        @(negedge clk);
        read_address = DEPTH - 1;
        #1;

        if (read_valid !== 1'b0 || read_record !== 64'd0)
            $fatal(1, "Old data exposed after clear");

        $display("PASS: Buffer reuse");

        // Reset while populated and requesting a write.
        @(negedge clk);
        rst          = 1'b1;
        write_enable = 1'b1;
        write_record = 64'hFFFF_FFFF_FFFF_FFFF;

        @(posedge clk);
        #1;
        check_empty;

        @(negedge clk);
        rst          = 1'b0;
        write_enable = 1'b0;
        #1;
        check_empty;

        $display("PASS: Reset takes priority over write");
        $display("PASS: All capture buffer checks completed.");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "Simulation timed out");
    end

endmodule