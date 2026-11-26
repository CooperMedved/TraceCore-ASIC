module capture_buffer#(
    parameter integer ADDR_WIDTH = 10
)(
    input wire clk,
    input wire rst,

    input wire clear,
    input wire write_enable,
    input wire [63:0] write_record,

    input wire [ADDR_WIDTH-1:0] read_address,
    output wire [63:0] read_record,
    output wire read_valid,

    output wire full,
    output wire empty,
    output reg [ADDR_WIDTH:0] record_count
);


localparam integer DEPTH = (1 << ADDR_WIDTH);

localparam [ADDR_WIDTH:0] CAPACITY = {1'b1, {ADDR_WIDTH{1'b0}}};

reg [63:0] records [0:DEPTH-1];

reg [ADDR_WIDTH-1:0] write_address;

assign full = (record_count == CAPACITY);
assign empty = (record_count == 0);

assign read_valid = !rst && !clear &&  ({1'b0, read_address} < record_count);

assign read_record = read_valid ? records[read_address] : 64'd0;

 // Buffer bookkeeping.
    // Priority: reset, clear, then accepted write.
    always @(posedge clk) begin
        if (rst) begin
            write_address <= {ADDR_WIDTH{1'b0}};
            record_count  <= {(ADDR_WIDTH+1){1'b0}};
        end else if (clear) begin
            write_address <= {ADDR_WIDTH{1'b0}};
            record_count  <= {(ADDR_WIDTH+1){1'b0}};
        end else if (write_enable && !full) begin
            record_count <= record_count + 1'b1;

            // Keep the address at the final entry once full.
            if (write_address != {ADDR_WIDTH{1'b1}})
                write_address <= write_address + 1'b1;
        end
    end

    // Record storage. Old contents are invalidated by clearing
    // record_count, so the storage itself does not need reset.
    always @(posedge clk) begin
        if (!rst && !clear && write_enable && !full)
            records[write_address] <= write_record;
    end




endmodule