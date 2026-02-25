module SRAM_Control_Circuit (
    // Global Control
    input  wire        CLK,
    input  wire        RST,
    
    // Standard Interface (8-bit scaled)
    input  wire [2:0]  Word_addr,    // Reduced to 3 bits for 8 words
    input  wire [2:0]  Bit_addr,     // Reduced to 3 bits for 8 bits
    input  wire [7:0]  Data,         // 8-bit Input Data
    input  wire        wr_en,
    
    // CIM Interface (8-bit scaled)
    input  wire        CIM,          
    input  wire [2:0]  WL_auto,      // CIM Wordline address
    input  wire [2:0]  BL_auto,      // CIM Bitline address
    
    // BIST Block Interface (BIST_EN removed)
    input  wire [2:0]  bword_addr,   
    input  wire        BIST_data_in, // Singular Pin
    input  wire        BIST_wr_en,   
    
    // Outputs to 8x8 SRAM Array (Matching Diagram Notations)
    output reg  [2:0]  WS,           // Word Select [2:0]
    output reg  [7:0]  WA,           // Wordline Activation [7:0]
    output reg  [7:0]  WAB,          // Wordline Activation Bar [7:0]
    output reg  [7:0]  PreD,         // Pre-charge Data [7:0]
    output reg  [7:0]  write_bus     // 8-bit Internal Data
);

    // Pattern generator: Expands 1-bit BIST to 8-bit word
    wire [7:0] bist_pattern = {8{BIST_data_in}};

    // --- Control Multiplexing ---
    always @(*) begin
        if (CIM) begin
            WS        = WL_auto;
            write_bus = 8'h00;        // Array driven by compute path
        end 
        else if (BIST_wr_en) begin
            WS        = bword_addr;
            write_bus = bist_pattern;
        end 
        else begin
            WS        = Word_addr;
            write_bus = Data;
        end
    end

    // --- Row/Wordline & Precharge Logic ---
    // Scaled to drive 8 rows instead of 32
    always @(posedge CLK or posedge RST) begin
        if (RST) begin
            WA   <= 8'h00;
            WAB  <= 8'hFF;            // Active Low Bar
            PreD <= 8'h00;
        end 
        else begin
            // 3-to-8 Bit Decoder for Wordlines
            WA   <= (8'b1 << WS);
            WAB  <= ~(8'b1 << WS);

            // Pre-charge (PreD) Management
            // Active during Read or CIM, disabled during any Write
            if (wr_en || BIST_wr_en) begin
                PreD <= 8'h00;        // Pre-charge OFF
            end 
            else begin
                PreD <= 8'hFF;        // Pre-charge ON
            end
        end
    end

endmodule


`timescale 1ns / 1ps

module tb_SRAM_Control_Circuit();

    // Inputs
    reg CLK;
    reg RST;
    reg [2:0] Word_addr;
    reg [2:0] Bit_addr;
    reg [7:0] Data;
    reg wr_en;
    reg CIM;
    reg [2:0] WL_auto;
    reg [2:0] BL_auto;
    reg [2:0] bword_addr;
    reg BIST_data_in;
    reg BIST_wr_en;

    // Outputs
    wire [2:0] WS;
    wire [7:0] WA;
    wire [7:0] WAB;
    wire [7:0] PreD;
    wire [7:0] write_bus;

    // Instantiate the Unit Under Test (UUT)
    SRAM_Control_Circuit uut (
        .CLK(CLK), .RST(RST),
        .Word_addr(Word_addr), .Bit_addr(Bit_addr), .Data(Data), .wr_en(wr_en),
        .CIM(CIM), .WL_auto(WL_auto), .BL_auto(BL_auto),
        .bword_addr(bword_addr), .BIST_data_in(BIST_data_in), .BIST_wr_en(BIST_wr_en),
        .WS(WS), .WA(WA), .WAB(WAB), .PreD(PreD), .write_bus(write_bus)
    );

    // Clock Generation
    always #5 CLK = ~CLK;

    initial begin
        // Initialize Inputs
        CLK = 0; RST = 1; Word_addr = 0; Bit_addr = 0; Data = 0; wr_en = 0;
        CIM = 0; WL_auto = 0; BL_auto = 0; bword_addr = 0; BIST_data_in = 0; BIST_wr_en = 0;

        // Reset Sequence
        #20 RST = 0;
        $display("--- Starting SRAM Control Unit Test ---");

        // --- Test 1: Normal Write Operation ---
        // Writing 8'hAA to Word Address 3
        #10 Word_addr = 3'd3; Data = 8'hAA; wr_en = 1;
        #10; // Observe WA[3] should be high, PreD should be low
        $display("Test 1 (Normal Write): WS=%d, write_bus=%h, WA=%b, PreD=%b", WS, write_bus, WA, PreD);

        // --- Test 2: Normal Read (Idle Write) ---
        #10 wr_en = 0;
        #10; // PreD should go high for read/idle
        $display("Test 2 (Normal Read): PreD=%b (Expected 11111111)", PreD);

        // --- Test 3: BIST Write Mode ---
        // Pattern 1 expanded to 8-bit (8'hFF) to BIST Address 5
        #10 BIST_wr_en = 1; bword_addr = 3'd5; BIST_data_in = 1;
        #10;
        $display("Test 3 (BIST Write): WS=%d, write_bus=%h (Expected FF), WA=%b", WS, write_bus, WA);

        // --- Test 4: CIM Mode Priority ---
        // Activate CIM while BIST is still trying to write. CIM should take control.
        #10 CIM = 1; WL_auto = 3'd7;
        #10;
        $display("Test 4 (CIM Mode): WS=%d (Expected 7), write_bus=%h (Expected 00)", WS, write_bus);

        // --- Test 5: Check Differential Wordline (WAB) ---
        #10 if (WA == ~WAB) 
                $display("Test 5 (Differential): Pass (WAB is inverse of WA)");
            else 
                $display("Test 5 (Differential): Fail");

        #50 $finish;
    end

endmodule

