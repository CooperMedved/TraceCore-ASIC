`timescale 1ns/1ps

module tracecore_top #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer MONITOR_BAUD_RATE = 115_200,
    parameter integer OUTPUT_BAUD_RATE  = 115_200,
    parameter integer ADDR_WIDTH        = 10
)(
    input  wire clk,
    input  wire rst,

    // Synchronous, one-clock command pulses.
    input  wire arm,
    input  wire stop,
    input  wire readout_start,

    // Configuration sampled when arm is accepted.
    input  wire       protocol_select,
    input  wire       trigger_enable,
    input  wire [7:0] trigger_byte,

    // Monitored SPI interface.
    input  wire spi_sclk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    input  wire spi_miso,

    // Monitored UART input.
    input  wire uart_rx,

    // UART output to PC.
    output wire uart_tx_out,

    output wire capture_busy,
    output wire capture_done,
    output wire readout_busy,
    output wire readout_done,
    output wire readout_error,

    output wire buffer_full,
    output wire buffer_empty,
    output wire [ADDR_WIDTH:0] record_count
);

    wire spi_enable;
    wire uart_enable;

    wire [7:0] spi_mosi_byte;
    wire [7:0] spi_miso_byte;
    wire [7:0] uart_rx_byte;

    wire spi_byte_valid;
    wire uart_byte_valid;
    wire uart_framing_error;

    wire spi_transaction_start;
    wire spi_transaction_end;

    wire buffer_clear;
    wire buffer_write;
    wire [63:0] buffer_record;

    wire [ADDR_WIDTH-1:0] read_address;
    wire [63:0] read_record;
    wire read_valid;

    wire tx_start;
    wire tx_busy;
    wire tx_done;
    wire [7:0] tx_data;

    wire accepted_arm;
    wire accepted_readout;

    // Capture and readout are mutually exclusive.
    // If both commands arrive while idle, arm takes priority.
    // Commands received while busy are ignored, not queued.
    assign accepted_arm = arm &&
                          !stop &&
                          !capture_busy &&
                          !readout_busy &&
                          !rst;

    assign accepted_readout = readout_start &&
                              !capture_busy &&
                              !readout_busy &&
                              !accepted_arm &&
                              !rst;

    spi_monitor u_spi_monitor (
        .clk              (clk),
        .rst              (rst),
        .enable           (spi_enable),
        .spi_sclk         (spi_sclk),
        .spi_cs_n         (spi_cs_n),
        .spi_mosi         (spi_mosi),
        .spi_miso         (spi_miso),
        .mosi_byte        (spi_mosi_byte),
        .miso_byte        (spi_miso_byte),
        .byte_valid       (spi_byte_valid),
        .transaction_start(spi_transaction_start),
        .transaction_end  (spi_transaction_end)
    );

    uart_monitor #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (MONITOR_BAUD_RATE)
    ) u_uart_monitor (
        .clk          (clk),
        .rst          (rst),
        .enable       (uart_enable),
        .uart_rx      (uart_rx),
        .rx_byte      (uart_rx_byte),
        .byte_valid   (uart_byte_valid),
        .framing_error(uart_framing_error)
    );

    capture_controller u_capture_controller (
        .clk               (clk),
        .rst               (rst),
        .arm               (accepted_arm),
        .stop              (stop),
        .protocol_select   (protocol_select),
        .trigger_enable    (trigger_enable),
        .trigger_byte      (trigger_byte),
        .spi_mosi_byte     (spi_mosi_byte),
        .spi_miso_byte     (spi_miso_byte),
        .spi_byte_valid    (spi_byte_valid),
        .uart_rx_byte      (uart_rx_byte),
        .uart_byte_valid   (uart_byte_valid),
        .uart_framing_error(uart_framing_error),
        .buffer_full       (buffer_full),
        .buffer_clear      (buffer_clear),
        .buffer_write      (buffer_write),
        .buffer_record     (buffer_record),
        .spi_enable        (spi_enable),
        .uart_enable       (uart_enable),
        .busy              (capture_busy),
        .done              (capture_done)
    );

    capture_buffer #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_capture_buffer (
        .clk         (clk),
        .rst         (rst),
        .clear       (buffer_clear),
        .write_enable(buffer_write),
        .write_record(buffer_record),
        .read_address(read_address),
        .read_record (read_record),
        .read_valid  (read_valid),
        .full        (buffer_full),
        .empty       (buffer_empty),
        .record_count(record_count)
    );

    capture_readout #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_capture_readout (
        .clk         (clk),
        .rst         (rst),
        .start       (accepted_readout),
        .record_count(record_count),
        .read_address(read_address),
        .read_record (read_record),
        .read_valid  (read_valid),
        .tx_busy     (tx_busy),
        .tx_done     (tx_done),
        .tx_start    (tx_start),
        .tx_data     (tx_data),
        .busy        (readout_busy),
        .done        (readout_done),
        .error       (readout_error)
    );

    uart_tx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE  (OUTPUT_BAUD_RATE)
    ) u_uart_tx (
        .clk    (clk),
        .rst    (rst),
        .start  (tx_start),
        .data_in(tx_data),
        .tx     (uart_tx_out),
        .busy   (tx_busy),
        .done   (tx_done)
    );

endmodule