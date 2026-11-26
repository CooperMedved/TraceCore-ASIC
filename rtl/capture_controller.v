module capture_controller (
    input  wire        clk,
    input  wire        rst,

    // One-clock command pulses
    input  wire        arm,
    input  wire        stop,

    // Configuration sampled when armed
    input  wire        protocol_select,  // 0 = SPI, 1 = UART
    input  wire        trigger_enable,
    input  wire [7:0]  trigger_byte,

    // SPI monitor outputs
    input  wire [7:0]  spi_mosi_byte,
    input  wire [7:0]  spi_miso_byte,
    input  wire        spi_byte_valid,

    // UART monitor outputs
    input  wire [7:0]  uart_rx_byte,
    input  wire        uart_byte_valid,
    input  wire        uart_framing_error,

    // Capture buffer interface
    input  wire        buffer_full,
    output wire        buffer_clear,
    output wire        buffer_write,
    output wire [63:0] buffer_record,

    // Monitor enables
    output wire        spi_enable,
    output wire        uart_enable,

    // Status
    output wire        busy,
    output reg         done
);

    localparam [1:0] IDLE         = 2'd0;
    localparam [1:0] WAIT_TRIGGER = 2'd1;
    localparam [1:0] CAPTURE      = 2'd2;

    reg [1:0]  state;
    reg [31:0] timestamp;
    reg        selected_protocol;
    reg [7:0]  selected_trigger;

    wire       event_valid;
    wire       event_error;
    wire [7:0] event_data;
    wire [7:0] event_miso;
    wire       trigger_match;

    // Status and monitor control
    assign busy = (state == WAIT_TRIGGER) || (state == CAPTURE);

    assign spi_enable  = busy && !selected_protocol && !stop && !rst;
    assign uart_enable = busy &&  selected_protocol && !stop && !rst;

    // Clear the buffer when a new arm command is accepted.
    assign buffer_clear = (state == IDLE) && arm && !stop && !rst;

    // Select events from the configured protocol.
    assign event_valid = selected_protocol
                       ? (uart_byte_valid || uart_framing_error)
                       : spi_byte_valid;

    assign event_error = selected_protocol && uart_framing_error;

    // A UART framing error has no valid received data.
    assign event_data = selected_protocol
                      ? (event_error ? 8'd0 : uart_rx_byte)
                      : spi_mosi_byte;

    assign event_miso = selected_protocol ? 8'd0 : spi_miso_byte;

    // Error records cannot satisfy a byte-match trigger.
    assign trigger_match = event_valid &&
                           !event_error &&
                           (event_data == selected_trigger);

    // Include the matching event as the first captured record.
    assign buffer_write = !rst &&
                          !stop &&
                          !buffer_full &&
                          event_valid &&
                          ((state == CAPTURE) ||
                           ((state == WAIT_TRIGGER) && trigger_match));

    // 32-bit timestamp, 8-bit flags, 8-bit protocol,
    // 8-bit MISO, and 8-bit MOSI/UART data.
    assign buffer_record = {
        timestamp,
        7'b0000000, event_error,
        7'b0000000, selected_protocol,
        event_miso,
        event_data
    };

    always @(posedge clk) begin
        if (rst) begin
            state             <= IDLE;
            timestamp         <= 32'd0;
            selected_protocol <= 1'b0;
            selected_trigger  <= 8'd0;
            done              <= 1'b0;
        end else begin
            // Completion is a one-clock pulse.
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (arm && !stop) begin
                        timestamp         <= 32'd0;
                        selected_protocol <= protocol_select;
                        selected_trigger  <= trigger_byte;

                        if (trigger_enable)
                            state <= WAIT_TRIGGER;
                        else
                            state <= CAPTURE;
                    end
                end

                WAIT_TRIGGER: begin
                    timestamp <= timestamp + 32'd1;

                    if (stop || buffer_full) begin
                        state <= IDLE;
                        done  <= 1'b1;
                    end else if (trigger_match) begin
                        state <= CAPTURE;
                    end
                end

                CAPTURE: begin
                    timestamp <= timestamp + 32'd1;

                    if (stop || buffer_full) begin
                        state <= IDLE;
                        done  <= 1'b1;
                    end
                end

                default: begin
                    state     <= IDLE;
                    timestamp <= 32'd0;
                end
            endcase
        end
    end

endmodule