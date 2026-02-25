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



`timescale 1ns / 1ps

module CIM_Control_tb();

    reg clk;
    reg rst_n;
    reg MUL;
    reg CIM;
    reg [4:0] Augend_addr;
    reg [4:0] Addend_addr;
    reg [4:0] Product_addr;

    // Outputs
    wire Dffwr, Cimprec, WRSel, Dffwrb, DffC;
    wire [4:0] WL_auto, S_addr;

    // Instantiate Unit Under Test (UUT)
    CIM_Control_Circuit uut (
        .clk(clk),
        .rst_n(rst_n),
        .MUL(MUL),
        .CIM(CIM),
        .Augend_addr(Augend_addr),
        .Addend_addr(Addend_addr),
        .Product_addr(Product_addr),
        .Sign_addr(5'd0),
        .Dffwr(Dffwr),
        .Cimprec(Cimprec),
        .WRSel(WRSel),
        .Dffwrb(Dffwrb),
        .DffC(DffC),
        .WL_auto(WL_auto),
        .S_addr(S_addr)
    );

    // Clock generation (100MHz)
    always #5 clk = ~clk;

    initial begin
        // Initialize
        clk = 0;
        rst_n = 0;
        MUL = 0;
        CIM = 0;
        Augend_addr = 5'd10;
        Addend_addr = 5'd11;
        Product_addr = 5'd20;

        // Reset sequence
        #20 rst_n = 1;
        #10;

        // Scenario 1: Start a Multiplication Operation
        $display("T=%0t | Starting MUL Operation", $time);
        MUL = 1;
        
        // Wait for WRITE_BACK state
        wait(Dffwrb == 1);
        $display("T=%0t | Write-Back detected to Address: %d", $time, S_addr);
        
        #20;
        MUL = 0;
        
        #50;
        $display("T=%0t | Test Complete", $time);
        $finish;
    end

    // Monitor transitions
    initial begin
        $monitor("Time=%0t | State=%b | WRSel=%b | DffC=%b | Dffwrb=%b | WL=%d", 
                 $time, uut.state, WRSel, DffC, Dffwrb, WL_auto);
    end

endmodule