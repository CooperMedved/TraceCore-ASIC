module uart_tx #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE   = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       start,
    input  wire [7:0] data_in,

    output reg        tx,
    output reg        busy,
    output reg        done
);

    // Requires positive parameters and CLKS_PER_BIT >= 1.
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD_RATE;

    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    reg [1:0]  state;
    reg [31:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  tx_data;

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
            tx_data   <= 8'd0;
            tx        <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b0;
        end else begin
            // Completion pulse defaults low.
            done <= 1'b0;

            case (state)
                IDLE: begin
                    tx        <= 1'b1;
                    busy      <= 1'b0;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;

                    // Accept a byte and begin its start bit.
                    if (start) begin
                        tx_data <= data_in;
                        tx      <= 1'b0;
                        busy    <= 1'b1;
                        state   <= START;
                    end
                end

                START: begin
                    // Hold start bit low for one bit period.
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        tx        <= tx_data[0];
                        state     <= DATA;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                DATA: begin
                    // Transmit eight data bits, LSB first.
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;

                        if (bit_index == 3'd7) begin
                            tx    <= 1'b1;
                            state <= STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                            tx        <= tx_data[bit_index + 3'd1];
                        end
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                STOP: begin
                    // Complete the full high stop-bit period.
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        busy      <= 1'b0;
                        done      <= 1'b1;
                        state     <= IDLE;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                default: begin
                    state     <= IDLE;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    tx        <= 1'b1;
                    busy      <= 1'b0;
                end
            endcase
        end
    end

endmodule