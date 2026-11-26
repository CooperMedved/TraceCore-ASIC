module capture_readout #(
    parameter integer ADDR_WIDTH = 10
)(
    input  wire                  clk,
    input  wire                  rst,

    // Pulse start after capture has stopped.
    input  wire                  start,

    // Capture buffer interface
    input  wire [ADDR_WIDTH:0]   record_count,
    output reg  [ADDR_WIDTH-1:0] read_address,
    input  wire [63:0]           read_record,
    input  wire                  read_valid,

    // UART transmitter interface
    input  wire                  tx_busy,
    input  wire                  tx_done,
    output wire                  tx_start,
    output wire [7:0]            tx_data,

    // Readout status
    output wire                  busy,
    output reg                   done,
    output reg                   error
);

    localparam [1:0] IDLE    = 2'd0;
    localparam [1:0] LOAD    = 2'd1;
    localparam [1:0] SEND    = 2'd2;
    localparam [1:0] WAIT_TX = 2'd3;

    reg [1:0] state;

    reg [63:0] record_shift;
    reg [2:0]  byte_index;

    // Includes the record currently being transmitted.
    reg [ADDR_WIDTH:0] records_remaining;

    assign busy = (state != IDLE);

    // SEND lasts until the transmitter can accept a byte.
    // On that clock edge, UART accepts start and this FSM
    // transitions to WAIT_TX.
    assign tx_start = !rst && (state == SEND) && !tx_busy;
    assign tx_data  = record_shift[7:0];

    always @(posedge clk) begin
        if (rst) begin
            state             <= IDLE;
            read_address      <= {ADDR_WIDTH{1'b0}};
            records_remaining <= {(ADDR_WIDTH+1){1'b0}};
            record_shift      <= 64'd0;
            byte_index        <= 3'd0;
            done              <= 1'b0;
            error             <= 1'b0;
        end else begin
            done  <= 1'b0;
            error <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        read_address      <= {ADDR_WIDTH{1'b0}};
                        records_remaining <= record_count;
                        record_shift      <= 64'd0;
                        byte_index        <= 3'd0;

                        if (record_count == 0) begin
                            // Nothing to transmit.
                            done <= 1'b1;
                        end else begin
                            state <= LOAD;
                        end
                    end
                end

                LOAD: begin
                    // The buffer provides an asynchronous read.
                    // Address was set before entering this state.
                    if (read_valid) begin
                        record_shift <= read_record;
                        byte_index   <= 3'd0;
                        state        <= SEND;
                    end else begin
                        // Abort if the requested record is invalid.
                        records_remaining <= {(ADDR_WIDTH+1){1'b0}};
                        error             <= 1'b1;
                        state             <= IDLE;
                    end
                end

                SEND: begin
                    if (!tx_busy) begin
                        // tx_start is asserted combinationally.
                        state <= WAIT_TX;
                    end
                end

                WAIT_TX: begin
                    if (tx_done) begin
                        if (byte_index == 3'd7) begin
                            // All eight bytes of this record sent.
                            if (records_remaining == 1) begin
                                records_remaining <=
                                    {(ADDR_WIDTH+1){1'b0}};

                                done  <= 1'b1;
                                state <= IDLE;
                            end else begin
                                records_remaining <=
                                    records_remaining - 1'b1;

                                read_address <= read_address + 1'b1;
                                state        <= LOAD;
                            end
                        end else begin
                            // Move the next byte into bits [7:0].
                            record_shift <= {
                                8'd0, record_shift[63:8]
                            };

                            byte_index <= byte_index + 3'd1;
                            state      <= SEND;
                        end
                    end
                end

                default: begin
                    state             <= IDLE;
                    records_remaining <= {(ADDR_WIDTH+1){1'b0}};
                    error             <= 1'b1;
                end
            endcase
        end
    end

endmodule