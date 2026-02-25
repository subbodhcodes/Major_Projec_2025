module Column_Decoder (
    input  wire [2:0]  WS,             // Column address part of WS
    output reg  [7:0]  Col_Select_EN   // Enable signals for Column Selector
);

    // Using a behavioral 'case' for clarity
    always @(*) begin
        case (WS)
            3'b000:  Col_Select_EN = 8'b00000001;
            3'b001:  Col_Select_EN = 8'b00000010;
            3'b010:  Col_Select_EN = 8'b00000100;
            3'b011:  Col_Select_EN = 8'b00001000;
            3'b100:  Col_Select_EN = 8'b00010000;
            3'b101:  Col_Select_EN = 8'b00100000;
            3'b110:  Col_Select_EN = 8'b01000000;
            3'b111:  Col_Select_EN = 8'b10000000;
            default: Col_Select_EN = 8'b00000000;
        endcase
    end

endmodule


module Column_Selector (
    input  wire [7:0]  bitlines,      // Data coming from the 8 columns
    input  wire [7:0]  sel_en,        // From Column Decoder
    output wire        Data_out       // Singular Data_out pin as in diagram
);

    // This mimics the pass-transistor logic of the Column Selector
    assign Data_out = (sel_en[0] & bitlines[0]) |
                      (sel_en[1] & bitlines[1]) |
                      (sel_en[2] & bitlines[2]) |
                      (sel_en[3] & bitlines[3]) |
                      (sel_en[4] & bitlines[4]) |
                      (sel_en[5] & bitlines[5]) |
                      (sel_en[6] & bitlines[6]) |
                      (sel_en[7] & bitlines[7]);

endmodule

