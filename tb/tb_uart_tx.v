`timescale 1ns/1ps

module tb_uart_tx;

    localparam integer CLK_FREQ_HZ = 100_000_000;
    localparam integer BAUD_RATE   = 115_200;
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    reg clk;
    reg rst;
    reg start;
    reg [7:0] data_in;

    wire tx;
    wire busy;
    wire done;

    integer done_count;
    reg previous_done;

    uart_tx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) dut (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .data_in(data_in),
        .tx     (tx),
        .busy   (busy),
        .done   (done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Check completion pulse width and status.
    always @(negedge clk) begin
        if (rst) begin
            done_count    = 0;
            previous_done = 1'b0;
        end else begin
            if (done !== 1'b0 && done !== 1'b1)
                $fatal(1, "done is unknown");

            if (done && previous_done)
                $fatal(1, "done lasted longer than one clock");

            if (done) begin
                if (busy !== 1'b0 || tx !== 1'b1)
                    $fatal(1, "Incorrect status at completion");

                done_count = done_count + 1;
            end

            previous_done = done;
        end
    end

    task check_frame;
        input [7:0] data;
        input       inject_busy_request;

        integer cycle;
        integer data_bit;
        reg expected_tx;

        begin
            if (busy !== 1'b0)
                $fatal(1, "Transmitter was not idle");

            // Present a one-clock start request.
            @(negedge clk);
            #1;
            data_in = data;
            start   = 1'b1;

            @(posedge clk);
            #1;

            if (tx !== 1'b0 || busy !== 1'b1 || done !== 1'b0)
                $fatal(1, "Start request was not accepted correctly");

            @(negedge clk);
            #1;
            start = 1'b0;

            // Changing data_in must not change the latched byte.
            data_in = ~data;

            // Check every clock interval of the complete frame:
            // start + 8 data bits + stop.
            for (cycle = 1;
                 cycle <= 10 * CLKS_PER_BIT;
                 cycle = cycle + 1) begin

                @(posedge clk);
                #1;

                if (cycle < CLKS_PER_BIT) begin
                    expected_tx = 1'b0;
                end else if (cycle < 9 * CLKS_PER_BIT) begin
                    data_bit = (cycle / CLKS_PER_BIT) - 1;
                    expected_tx = data[data_bit];
                end else begin
                    expected_tx = 1'b1;
                end

                if (tx !== expected_tx)
                    $fatal(1,
                        "Byte %h, cycle %0d: TX=%b expected=%b",
                        data, cycle, tx, expected_tx);

                if (cycle < 10 * CLKS_PER_BIT) begin
                    if (busy !== 1'b1 || done !== 1'b0)
                        $fatal(1, "Transmission ended early");
                end else begin
                    if (busy !== 1'b0 || done !== 1'b1)
                        $fatal(1, "Incorrect completion timing");
                end

                @(negedge clk);
                #1;

                // An extra request while busy must be ignored.
                if (inject_busy_request &&
                    cycle == 2 * CLKS_PER_BIT) begin
                    start   = 1'b1;
                    data_in = 8'hFF;
                end else begin
                    start = 1'b0;
                end
            end

            // Confirm done clears and no extra frame starts.
            repeat (3) begin
                @(posedge clk);
                #1;

                if (tx !== 1'b1 ||
                    busy !== 1'b0 ||
                    done !== 1'b0)
                    $fatal(1, "Transmitter failed to return to idle");
            end

            $display("PASS: Transmitted %h", data);
        end
    endtask

    initial begin
        $dumpfile("build/uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);

        rst     = 1'b1;
        start   = 1'b0;
        data_in = 8'd0;

        repeat (3) @(posedge clk);
        #1;

        if (tx !== 1'b1 || busy !== 1'b0 || done !== 1'b0)
            $fatal(1, "Incorrect reset outputs");

        @(negedge clk);
        #1;
        rst = 1'b0;

        check_frame(8'hA5, 1'b0);
        check_frame(8'h3C, 1'b1);
        check_frame(8'h00, 1'b0);
        check_frame(8'hFF, 1'b0);

        if (done_count != 4)
            $fatal(1, "Expected 4 completion pulses, received %0d",
                   done_count);

        $display("PASS: All UART transmitter checks completed.");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "Simulation timed out");
    end

endmodule