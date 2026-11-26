module uart_monitor #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    input  wire       uart_rx,

    output reg  [7:0] rx_byte,
    output reg        byte_valid,
    output reg        framing_error
);

    // Parameters must produce CLKS_PER_BIT >= 2.
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;
    localparam integer HALF_BIT_CLKS = CLKS_PER_BIT / 2;

    // Input synchronization
    reg rx_meta;
    reg rx_sync;

    always @(posedge clk) begin
        if (rst) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= uart_rx;
            rx_sync <= rx_meta;
        end
    end

    // Receive states
    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  rx_shift;

    // UART receiver: 8 data bits, no parity, 1 stop bit.
    always @(posedge clk) begin
        if (rst) begin
            state         <= IDLE;
            clk_count     <= 32'd0;
            bit_index     <= 3'd0;
            rx_shift      <= 8'd0;
            rx_byte       <= 8'd0;
            byte_valid    <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            // Status outputs are one-clock pulses.
            byte_valid    <= 1'b0;
            framing_error <= 1'b0;

            if (!enable) begin
                // Abort any frame currently being received.
                state     <= IDLE;
                clk_count <= 32'd0;
                bit_index <= 3'd0;
                rx_shift  <= 8'd0;
            end else begin
                case (state)
                    IDLE: begin
                        clk_count <= 32'd0;
                        bit_index <= 3'd0;

                        // A low level indicates a possible start.
                        if (rx_sync == 1'b0) begin
                            rx_shift <= 8'd0;
                            state    <= START;
                        end
                    end

                    START: begin
                        // Confirm the start bit near its center.
                        if (clk_count == HALF_BIT_CLKS - 1) begin
                            clk_count <= 32'd0;

                            if (rx_sync == 1'b0) begin
                                bit_index <= 3'd0;
                                state     <= DATA;
                            end else begin
                                // False start.
                                state <= IDLE;
                            end
                        end else begin
                            clk_count <= clk_count + 32'd1;
                        end
                    end

                    DATA: begin
                        // Sample each data bit one bit period apart.
                        if (clk_count == CLKS_PER_BIT - 1) begin
                            clk_count <= 32'd0;

                            // UART transmits least significant bit first.
                            rx_shift[bit_index] <= rx_sync;

                            if (bit_index == 3'd7) begin
                                state <= STOP;
                            end else begin
                                bit_index <= bit_index + 3'd1;
                            end
                        end else begin
                            clk_count <= clk_count + 32'd1;
                        end
                    end

                    STOP: begin
                        // Check the stop bit near its center.
                        if (clk_count == CLKS_PER_BIT - 1) begin
                            clk_count <= 32'd0;
                            state     <= IDLE;

                            if (rx_sync == 1'b1) begin
                                rx_byte    <= rx_shift;
                                byte_valid <= 1'b1;
                            end else begin
                                // Discard frames with an invalid stop bit.
                                framing_error <= 1'b1;
                            end
                        end else begin
                            clk_count <= clk_count + 32'd1;
                        end
                    end

                    default: begin
                        state     <= IDLE;
                        clk_count <= 32'd0;
                        bit_index <= 3'd0;
                        rx_shift  <= 8'd0;
                    end
                endcase
            end
        end
    end

endmodule