// Shared testbench tasks.
// Requires serial_tx and BIT_NS in the including testbench.

task receive_byte;
    output [7:0] value;
    integer bit_number;

    begin
        @(negedge serial_tx);
        #(BIT_NS / 2.0);

        if (serial_tx !== 1'b0)
            $fatal(1, "Invalid TX start bit");

        for (bit_number = 0; bit_number < 8;
             bit_number = bit_number + 1) begin
            #(BIT_NS);
            value[bit_number] = serial_tx;
        end

        #(BIT_NS);

        if (serial_tx !== 1'b1)
            $fatal(1, "Invalid TX stop bit");
    end
endtask

task receive_record;
    output [63:0] value;
    reg [7:0] data_byte;
    integer byte_number;

    begin
        for (byte_number = 0; byte_number < 8;
             byte_number = byte_number + 1) begin
            receive_byte(data_byte);
            value[byte_number*8 +: 8] = data_byte;
        end
    end
endtask