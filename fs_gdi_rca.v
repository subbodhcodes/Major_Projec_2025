// 8-bit Renamed Ripple Carry Adder/Multiplier (RRCAM)
module rrcam_8bit (
    // Inputs from SRAM array peripheral
    input  wire [7:0] CAND,          // Multiplicand
    input  wire [7:0] CNOR,          // NOR logic operand
    input  wire [7:0] CB,            // Complementary Bitline operand

    // Outputs to the Write Back Circuit
    output wire [7:0] SUM,           // 8-bit Summation
    output wire [7:0] CO,            // 8-bit Carry Out bus
    output wire [7:0] Sign,          // 8-bit Sign bus
    output wire [7:0] Signproduct    // 8-bit Sign of Product bus
);

    // Carry chain internal wiring
    wire [8:0] carry_chain;
    assign carry_chain[0] = 1'b0;    // Standard carry-in for addition

    // Generate block for the bit-slice logic
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : RRCAM_GEN
            // Individual cell instantiation using renamed module
            rrcam_cell cell_inst (
                .CANDx(CAND[i]),
                .CNORx(CNOR[i]),
                .CBx(CB[i]),
                .CIx(carry_chain[i]),
                .SUMx(SUM[i]),
                .COx(carry_chain[i+1])
            );
        end
    endgenerate

    // Final assignments to match the diagram's 8-bit bus structure
    assign CO          = {7'b0, carry_chain[8]};       // Final carry out bit
    assign Sign        = {7'b0, SUM[7]};               // Sign of the result
    assign Signproduct = {7'b0, (CAND[7] ^ CB[7])};    // XOR logic for product sign

endmodule

// Renamed Cell Module
module rrcam_cell (
    input  wire CANDx,
    input  wire CNORx,
    input  wire CBx,
    input  wire CIx,
    output wire SUMx,
    output wire COx
);
    // Functional logic for the FS-GDI based adder slice
    assign SUMx = CANDx ^ CNORx ^ CBx ^ CIx;
    assign COx  = (CANDx & CNORx) | (CIx & (CANDx ^ CNORx ^ CBx));
endmodule


`timescale 1ns / 1ps

module tb_rrcam_8bit();

    // Test Signals
    reg  [7:0] CAND;
    reg  [7:0] CNOR;
    reg  [7:0] CB;
    wire [7:0] SUM;
    wire [7:0] CO;
    wire [7:0] Sign;
    wire [7:0] Signproduct;

    // Instantiate Renamed Unit Under Test (UUT)
    rrcam_8bit uut (
        .CAND(CAND),
        .CNOR(CNOR),
        .CB(CB),
        .SUM(SUM),
        .CO(CO),
        .Sign(Sign),
        .Signproduct(Signproduct)
    );

    initial begin
        $display("--- Starting RRCAM 8-bit Verification ---");
        
        // Test 1: Baseline Addition
        CAND = 8'd50; CNOR = 8'd25; CB = 8'd5;
        #10;
        $display("Test 1 [Addition]: SUM=%d (Exp: 80), CO[0]=%b", SUM, CO[0]);

        // Test 2: Carry Overflow
        CAND = 8'd150; CNOR = 8'd150; CB = 8'd0;
        #10;
        $display("Test 2 [Carry]: SUM=%d (Exp: 44), CO[0]=%b (Exp: 1)", SUM, CO[0]);

        // Test 3: Sign Bit Check
        CAND = 8'b10000000; // MSB is 1
        CNOR = 8'd0; CB = 8'd0;
        #10;
        $display("Test 3 [Sign]: Sign[0]=%b (Exp: 1)", Sign[0]);

        // Test 4: Product Sign Logic (Negative * Positive)
        CAND = 8'b10000000; // Sign Bit 1
        CB   = 8'b00000001; // Sign Bit 0
        CNOR = 8'b00000000;
        #10;
        $display("Test 4 [Prod Sign]: Signproduct[0]=%b (Exp: 1)", Signproduct[0]);

        #10 $finish;
    end

endmodule