`timescale 1ns / 1ps

module CIM_Control_Circuit #(
    parameter ADDR_W = 5,  // Supports 32 rows (as per image)
    parameter DATA_W = 8   // 8-bit TinyML precision
)(
    input  wire              clk,
    input  wire              rst_n,      // Active low reset
    
    // Command Interface
    input  wire              MUL,        // Multiply command
    input  wire              CIM,        // CIM command
    
    // Address Inputs (from Instruction Decoder/Processor)
    input  wire [ADDR_W-1:0] Augend_addr,
    input  wire [ADDR_W-1:0] Addend_addr,
    input  wire [ADDR_W-1:0] Product_addr,
    input  wire [ADDR_W-1:0] Sign_addr,
    
    // Control Outputs to Top-Level
    output reg               Dffwr,      // Main SRAM Write Trigger
    output reg               Cimprec,    // Precision Control (1 for 8-bit)
    output reg               WRSel,      // 0: Ext Data, 1: CIM Result
    output reg               Dffwrb,     // Write-back Strobe
    output reg               DffC,       // Compute Strobe
    
    // Auto-Address outputs to Decoders
    output reg  [ADDR_W-1:0] WL_auto,    // Maps to RWL or WWL
    output reg  [ADDR_W-1:0] S_addr,     // Storage target address
    output wire [ADDR_W-1:0] CIM_Data    // Data bus for internal routing
);

    // State Encoding
    localparam IDLE       = 3'b000;
    localparam READ_OPS   = 3'b001; // Activate RWL for operands
    localparam EXECUTE    = 3'b010; // Trigger FS-GDI Adder
    localparam WRITE_BACK = 3'b011; // Activate WWL for result
    localparam DONE       = 3'b100;

    reg [2:0] state, next_state;

    // State Transition
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= IDLE;
        else        state <= next_state;
    end

    // Next State and Output Logic
    always @(*) begin
        next_state = state;
        // Default values to prevent latches
        Dffwr   = 0;
        Cimprec = 1; // Default to 8-bit precision
        WRSel   = 0;
        Dffwrb  = 0;
        DffC    = 0;
        WL_auto = 0;
        S_addr  = 0;

        case (state)
            IDLE: begin
                if (MUL || CIM) next_state = READ_OPS;
            end

            READ_OPS: begin
                // In 8T cells, we activate RWL for the operands
                WL_auto = Augend_addr; 
                next_state = EXECUTE;
            end

            EXECUTE: begin
                DffC = 1; // Enable FS-GDI Adder computation
                next_state = WRITE_BACK;
            end

            WRITE_BACK: begin
                WRSel   = 1;            // Mux select for CIM result
                Dffwrb  = 1;            // Pulse write-back latch
                S_addr  = Product_addr; // Address to write to
                WL_auto = Product_addr; // WWL activation for 8T cell
                next_state = DONE;
            end

            DONE: begin
                if (!MUL && !CIM) next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end

    assign CIM_Data = WL_auto; // Simplified routing for this block

endmodule

// Updated Write-Back Logic with Enable Gate
module auto_switch_writeback_8bit (
    input  wire       clk, rst_n,
    input  wire       Cimprec, WRSel, Is_Mul, Dffwrb, // Added Dffwrb as Enable
    input  wire [4:0] WL_auto,
    input  wire [7:0] SUM, CO, Product, CIM_Data,
    output reg  [7:0] Write_Data_Bus,
    output reg  [4:0] WL_out
);
    reg [7:0] selected_result;
    always @(*) begin
        if (Is_Mul) selected_result = Product;
        else        selected_result = Cimprec ? {CO[0], SUM[6:0]} : SUM;
    end
    
    wire [7:0] final_mux_out = (WRSel) ? selected_result : CIM_Data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin 
            Write_Data_Bus <= 8'b0; 
            WL_out <= 5'b0; 
        end
        else if (Dffwrb) begin // Only update when the FSM triggers write-back
            Write_Data_Bus <= final_mux_out; 
            WL_out <= WL_auto; 
        end
    end
endmodule

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


