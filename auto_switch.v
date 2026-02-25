module auto_switch_writeback_8bit (
    input  wire        clk,
    input  wire        rst_n,

    // Control signals
    input  wire        Cimprec,  // High = Store Carry + Sum (High Precision)
    input  wire        WRSel,    // 0 = External/CIM Data, 1 = Arithmetic Result
    input  wire        Is_Mul,   // 1 = Multiplication result, 0 = Addition result

    // Auto address
    input  wire [4:0]  WL_auto,
    input  wire [4:0]  BL_auto,

    // Data inputs from RCAM
    input  wire [7:0]  SUM,      // Sum from Adder
    input  wire        CO,       // Final Carry from Adder
    input  wire [7:0]  Product,  // Result from Multiplier
    input  wire [7:0]  CIM_Data, // Direct bypass data

    // Outputs to SRAM Array
    output reg  [7:0]  Write_Data_Bus,
    output reg  [4:0]  WL_out,
    output reg  [4:0]  BL_out
);

    reg [7:0] selected_result;

    // 1. Data Selection (The "Middle Block" in Figure 7)
    always @(*) begin
        if (Is_Mul) begin
            // If Multiplier is active, result is the Product
            selected_result = Product;
        end else begin
            // If Addition is active:
            // High Precision (Cimprec=1) might store Carry in MSB or handle 9-bit logic
            // Standard Addition (Cimprec=0) stores the 8-bit SUM
            if (Cimprec)
                selected_result = {CO, SUM[6:0]}; // Example mapping: Carry + Sum
            else
                selected_result = SUM;
        end
    end

    // 2. Write-back source selection (MUX before the DFF)
    wire [7:0] final_mux_out = (WRSel) ? selected_result : CIM_Data;

    // 3. Registered Write-back (Timing Control)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            Write_Data_Bus <= 8'b0;
            WL_out         <= 5'b0;
            BL_out         <= 5'b0;
        end else begin
            // The result and addresses are latched only when Write-Back is enabled
            Write_Data_Bus <= final_mux_out;
            WL_out         <= WL_auto;
            BL_out         <= BL_auto;
        end
    end

endmodule

`timescale 1ns/1ps

module tb_auto_switch_writeback_8bit;

    // Clock and Reset
    reg clk;
    reg rst_n;

    // Control Signals
    reg Cimprec;
    reg WRSel;
    reg Is_Mul;

    // Addresses
    reg [4:0] WL_auto;
    reg [4:0] BL_auto;

    // Data from RCAM
    reg [7:0] SUM;
    reg       CO;
    reg [7:0] Product;
    reg [7:0] CIM_Data;

    // Outputs
    wire [7:0] Write_Data_Bus;
    wire [4:0] WL_out;
    wire [4:0] BL_out;

    // Instantiate the Corrected Module
    auto_switch_writeback_8bit dut (
        .clk(clk),
        .rst_n(rst_n),
        .Cimprec(Cimprec),
        .WRSel(WRSel),
        .Is_Mul(Is_Mul),
        .WL_auto(WL_auto),
        .BL_auto(BL_auto),
        .SUM(SUM),
        .CO(CO),
        .Product(Product),
        .CIM_Data(CIM_Data),
        .Write_Data_Bus(Write_Data_Bus),
        .WL_out(WL_out),
        .BL_out(BL_out)
    );

    // Clock Generation (100MHz)
    always #5 clk = ~clk;

    initial begin
        // Initialize Signals
        clk = 0;
        rst_n = 0;
        Cimprec = 0;
        WRSel = 0;
        Is_Mul = 0;
        WL_auto = 5'd0;
        BL_auto = 5'd0;
        SUM = 8'd0;
        CO = 0;
        Product = 8'd0;
        CIM_Data = 8'd0;

        // Reset Sequence
        #15 rst_n = 1;
        $display("Time\t Mode\t\t Address\t Data Out");
        $display("---------------------------------------------------------");

        // TEST 1: Bypass Mode (Writing external data to Address 5)
        // WRSel = 0 tells the MUX to ignore the ALU and use CIM_Data
        WRSel = 0;
        CIM_Data = 8'hA5;
        WL_auto = 5'd5;
        BL_auto = 5'd10;
        #10;
        $display("%0t\t Bypass\t\t WL:%d BL:%d\t %h (Expect A5)", $time, WL_out, BL_out, Write_Data_Bus);

        // TEST 2: Addition Write-back (25 + 15 = 40)
        // Set WRSel=1 (ALU Mode) and Is_Mul=0 (Addition)
        WRSel = 1;
        Is_Mul = 0;
        SUM = 8'd40;
        CO  = 0;
        WL_auto = 5'd12;
        BL_auto = 5'd2;
        #10;
        $display("%0t\t Addition\t WL:%d BL:%d\t %d (Expect 40)", $time, WL_out, BL_out, Write_Data_Bus);

        // TEST 3: Multiplication Write-back (12 * 3 = 36)
        // Set Is_Mul=1 to select the Product input
        Is_Mul = 1;
        Product = 8'd36;
        WL_auto = 5'd15;
        #10;
        $display("%0t\t Multiply\t WL:%d BL:%d\t %d (Expect 36)", $time, WL_out, BL_out, Write_Data_Bus);

        // TEST 4: High Precision Selection
        // Demonstrating how Cimprec can be used to pack Carry into the bus
        Is_Mul = 0;
        Cimprec = 1;
        SUM = 8'b01111111; // 127
        CO  = 1;           // Carry is set
        #10;
        $display("%0t\t HighPrec\t WL:%d BL:%d\t %b (Expect 1 in MSB)", $time, WL_out, BL_out, Write_Data_Bus);

        #20;
        $finish;
    end

endmodule