module spi_monitor (
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,

    input  wire       spi_sclk,
    input  wire       spi_cs_n,
    input  wire       spi_mosi,
    input  wire       spi_miso,

    output reg  [7:0] mosi_byte,
    output reg  [7:0] miso_byte,
    output reg        byte_valid,
    output reg        transaction_start,
    output reg        transaction_end
);

    // External input synchronizers
    reg sclk_meta;
    reg sclk_sync;
    reg cs_n_meta;
    reg cs_n_sync;
    reg mosi_meta;
    reg mosi_sync;
    reg miso_meta;
    reg miso_sync;

    // Previous values for edge detection
    reg sclk_prev;
    reg cs_n_prev;

    // Decoder state
    reg       active;
    reg [2:0] bit_count;
    reg [7:0] mosi_shift;
    reg [7:0] miso_shift;

    wire sclk_rising;
    wire cs_falling;
    wire cs_rising;

    assign sclk_rising =  sclk_sync & ~sclk_prev;
    assign cs_falling  = ~cs_n_sync &  cs_n_prev;
    assign cs_rising   =  cs_n_sync & ~cs_n_prev;

    // Synchronizers run continuously, even when disabled.
    always @(posedge clk) begin
        if (rst) begin
            sclk_meta <= 1'b0;
            sclk_sync <= 1'b0;
            sclk_prev <= 1'b0;

            cs_n_meta <= 1'b1;
            cs_n_sync <= 1'b1;
            cs_n_prev <= 1'b1;

            mosi_meta <= 1'b0;
            mosi_sync <= 1'b0;
            miso_meta <= 1'b0;
            miso_sync <= 1'b0;
        end else begin
            sclk_meta <= spi_sclk;
            sclk_sync <= sclk_meta;
            sclk_prev <= sclk_sync;

            cs_n_meta <= spi_cs_n;
            cs_n_sync <= cs_n_meta;
            cs_n_prev <= cs_n_sync;

            mosi_meta <= spi_mosi;
            mosi_sync <= mosi_meta;

            miso_meta <= spi_miso;
            miso_sync <= miso_meta;
        end
    end

    // SPI mode 0 decoder
    always @(posedge clk) begin
        if (rst) begin
            active            <= 1'b0;
            bit_count         <= 3'd0;
            mosi_shift        <= 8'd0;
            miso_shift        <= 8'd0;
            mosi_byte         <= 8'd0;
            miso_byte         <= 8'd0;
            byte_valid        <= 1'b0;
            transaction_start <= 1'b0;
            transaction_end   <= 1'b0;
        end else begin
            // Event outputs are one-clock pulses.
            byte_valid        <= 1'b0;
            transaction_start <= 1'b0;
            transaction_end   <= 1'b0;

            if (!enable) begin
                // Disabling aborts capture without an end pulse.
                active     <= 1'b0;
                bit_count  <= 3'd0;
                mosi_shift <= 8'd0;
                miso_shift <= 8'd0;
            end else if (cs_rising) begin
                // Finish a tracked transaction.
                transaction_end <= active;
                active          <= 1'b0;
                bit_count       <= 3'd0;
                mosi_shift      <= 8'd0;
                miso_shift      <= 8'd0;
            end else if (cs_falling) begin
                // Begin a new transaction.
                transaction_start <= 1'b1;
                active            <= 1'b1;
                bit_count         <= 3'd0;
                mosi_shift        <= 8'd0;
                miso_shift        <= 8'd0;
            end else if (active && !cs_n_sync && sclk_rising) begin
                // Shift left, inserting the newest bit at bit 0.
                mosi_shift <= {mosi_shift[6:0], mosi_sync};
                miso_shift <= {miso_shift[6:0], miso_sync};

                if (bit_count == 3'd7) begin
                    // Include the eighth bit in the published byte.
                    mosi_byte <= {mosi_shift[6:0], mosi_sync};
                    miso_byte <= {miso_shift[6:0], miso_sync};
                    byte_valid <= 1'b1;
                    bit_count  <= 3'd0;
                end else begin
                    bit_count <= bit_count + 3'd1;
                end
            end
        end
    end

endmodule