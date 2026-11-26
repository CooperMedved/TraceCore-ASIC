`timescale 1ns/1ps

module tb_spi_monitor;

    reg clk;
    reg rst;
    reg enable;

    reg spi_sclk;
    reg spi_cs_n;
    reg spi_mosi;
    reg spi_miso;

    wire [7:0] mosi_byte;
    wire [7:0] miso_byte;
    wire byte_valid;
    wire transaction_start;
    wire transaction_end;

    reg [7:0] tx_mosi;
    reg [7:0] tx_miso;

    integer i;
    integer byte_index;
    integer byte_count;
    integer start_count;
    integer end_count;

    spi_monitor dut (
        .clk               (clk),
        .rst               (rst),
        .enable            (enable),
        .spi_sclk          (spi_sclk),
        .spi_cs_n          (spi_cs_n),
        .spi_mosi          (spi_mosi),
        .spi_miso          (spi_miso),
        .mosi_byte         (mosi_byte),
        .miso_byte         (miso_byte),
        .byte_valid        (byte_valid),
        .transaction_start(transaction_start),
        .transaction_end  (transaction_end)
    );

    // Internal clock: 100 MHz
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Check outputs after rising-edge updates.
    always @(negedge clk) begin
        if (rst) begin
            byte_count  = 0;
            start_count = 0;
            end_count   = 0;
        end else begin
            if (transaction_start === 1'b1) begin
                start_count = start_count + 1;
                $display("[%0t] Transaction started", $time);
            end

            if (byte_valid === 1'b1) begin
                // Expected values depend on received byte order.
                case (byte_count)
                    0: begin
                        if (mosi_byte !== 8'hA5 ||
                            miso_byte !== 8'h3C)
                            $fatal(1,
                                "Byte 0 mismatch: MOSI=%h MISO=%h",
                                mosi_byte, miso_byte);
                    end

                    1: begin
                        if (mosi_byte !== 8'h96 ||
                            miso_byte !== 8'hE1)
                            $fatal(1,
                                "Byte 1 mismatch: MOSI=%h MISO=%h",
                                mosi_byte, miso_byte);
                    end

                    default:
                        $fatal(1, "Unexpected extra byte");
                endcase

                $display("[%0t] Byte %0d correct: MOSI=%h MISO=%h",
                         $time, byte_count, mosi_byte, miso_byte);

                byte_count = byte_count + 1;
            end

            if (transaction_end === 1'b1) begin
                end_count = end_count + 1;
                $display("[%0t] Transaction ended", $time);
            end
        end
    end

    initial begin
        $dumpfile("build/spi_monitor.vcd");
        $dumpvars(0, tb_spi_monitor);

        rst      = 1'b1;
        enable   = 1'b0;
        spi_sclk = 1'b0;
        spi_cs_n = 1'b1;
        spi_mosi = 1'b0;
        spi_miso = 1'b0;
        tx_mosi  = 8'd0;
        tx_miso  = 8'd0;

        // Offset stimulus from clock edges to avoid races.
        repeat (4) @(negedge clk);
        #1;
        rst = 1'b0;

        repeat (2) @(negedge clk);
        #1;
        enable = 1'b1;

        // Begin one transaction containing two bytes.
        #100;
        spi_cs_n = 1'b0;
        #100;

        for (byte_index = 0; byte_index < 2;
             byte_index = byte_index + 1) begin

            if (byte_index == 0) begin
                tx_mosi = 8'hA5;
                tx_miso = 8'h3C;
            end else begin
                tx_mosi = 8'h96;
                tx_miso = 8'hE1;
            end

            // SPI mode 0, MSB first, 5 MHz.
            for (i = 7; i >= 0; i = i - 1) begin
                spi_mosi = tx_mosi[i];
                spi_miso = tx_miso[i];

                #100;
                spi_sclk = 1'b1;

                #100;
                spi_sclk = 1'b0;
            end
        end

        // End transaction after both bytes.
        #100;
        spi_cs_n = 1'b1;

        // Allow synchronized events to propagate.
        #200;

        if (byte_count != 2)
            $fatal(1, "Expected 2 bytes, received %0d", byte_count);

        if (start_count != 1)
            $fatal(1, "Expected 1 start pulse, received %0d",
                   start_count);

        if (end_count != 1)
            $fatal(1, "Expected 1 end pulse, received %0d",
                   end_count);

        $display("PASS: Two-byte SPI transaction verified.");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "Simulation timed out.");
    end

endmodule