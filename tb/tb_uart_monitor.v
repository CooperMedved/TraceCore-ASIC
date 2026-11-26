`timescale 1ns/1ps

module tb_uart_monitor;

    localparam integer CLK_FREQ_HZ = 100_000_000;
    localparam integer BAUD_RATE   = 115_200;

    // Model the transmitting device's baud rate independently.
    localparam real BIT_PERIOD_NS = 1_000_000_000.0 / BAUD_RATE;

    reg clk;
    reg rst;
    reg enable;
    reg uart_rx;

    wire [7:0] rx_byte;
    wire byte_valid;
    wire framing_error;

    integer byte_count;
    integer error_count;

    reg previous_valid;
    reg previous_error;

    uart_monitor #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (BAUD_RATE)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .enable       (enable),
        .uart_rx      (uart_rx),
        .rx_byte      (rx_byte),
        .byte_valid   (byte_valid),
        .framing_error(framing_error)
    );

    // 100 MHz internal clock.
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Send an 8N1 frame, least significant bit first.
    task send_frame;
        input [7:0] data;
        input       bad_stop;
        integer bit_number;
        begin
            uart_rx = 1'b0;
            #(BIT_PERIOD_NS);

            for (bit_number = 0; bit_number < 8;
                 bit_number = bit_number + 1) begin
                uart_rx = data[bit_number];
                #(BIT_PERIOD_NS);
            end

            uart_rx = bad_stop ? 1'b0 : 1'b1;
            #(BIT_PERIOD_NS);

            // Return to idle and allow recovery.
            uart_rx = 1'b1;
            #(BIT_PERIOD_NS);
        end
    endtask

    // Check outputs after the DUT's rising-edge updates.
    always @(negedge clk) begin
        if (rst) begin
            byte_count     = 0;
            error_count    = 0;
            previous_valid = 1'b0;
            previous_error = 1'b0;
        end else begin
            if (byte_valid !== 1'b0 && byte_valid !== 1'b1)
                $fatal(1, "byte_valid is unknown");

            if (framing_error !== 1'b0 && framing_error !== 1'b1)
                $fatal(1, "framing_error is unknown");

            if (byte_valid && previous_valid)
                $fatal(1, "byte_valid lasted longer than one clock");

            if (framing_error && previous_error)
                $fatal(1, "framing_error lasted longer than one clock");

            if (byte_valid && framing_error)
                $fatal(1, "Valid byte and framing error asserted together");

            if (byte_valid) begin
                case (byte_count)
                    0: begin
                        if (rx_byte !== 8'hA5)
                            $fatal(1, "Expected A5, received %h", rx_byte);
                    end

                    1: begin
                        if (rx_byte !== 8'h3C)
                            $fatal(1, "Expected 3C, received %h", rx_byte);
                    end

                    default:
                        $fatal(1, "Unexpected extra byte: %h", rx_byte);
                endcase

                $display("Received expected byte: %h", rx_byte);
                byte_count = byte_count + 1;
            end

            if (framing_error) begin
                error_count = error_count + 1;
                $display("Detected framing error");
            end

            previous_valid = byte_valid;
            previous_error = framing_error;
        end
    end

    initial begin
        $dumpfile("build/uart_monitor.vcd");
        $dumpvars(0, tb_uart_monitor);

        rst     = 1'b1;
        enable  = 1'b0;
        uart_rx = 1'b1;

        repeat (4) @(negedge clk);
        #1;
        rst = 1'b0;

        repeat (2) @(negedge clk);
        #1;
        enable = 1'b1;

        #(BIT_PERIOD_NS);

        // Two valid frames.
        send_frame(8'hA5, 1'b0);
        send_frame(8'h3C, 1'b0);

        if (byte_count != 2 || error_count != 0)
            $fatal(1, "Valid-frame check failed: bytes=%0d errors=%0d",
                   byte_count, error_count);

        // Invalid stop bit: must not publish a byte.
        send_frame(8'h96, 1'b1);

        #200;

        if (byte_count != 2)
            $fatal(1, "Expected 2 valid bytes, received %0d", byte_count);

        if (error_count != 1)
            $fatal(1, "Expected 1 framing error, received %0d",
                   error_count);

        if (rx_byte !== 8'h3C)
            $fatal(1, "Invalid frame changed rx_byte");

        $display("PASS: UART valid bytes and framing error verified.");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "Simulation timed out");
    end

endmodule