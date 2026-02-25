`timescale 1ns / 1ps
// ============================================================
// 5. TOP LEVEL SYSTEM
// ============================================================
module CIM_Top_System (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        MUL,
    input  wire        CIM,
    input  wire [2:0]  ext_word_addr,
    input  wire [7:0]  ext_write_data,
    input  wire        ext_wr_en,
    input  wire [4:0]  Augend_addr,
    input  wire [4:0]  Addend_addr,
    input  wire [4:0]  Product_addr,
    input  wire [7:0]  SRAM_CAND, 
    input  wire [7:0]  SRAM_CNOR,
    input  wire [7:0]  SRAM_CB,
    output wire [7:0]  System_Data_Bus,
    output wire [4:0]  System_WL_Out,
    output wire [7:0]  System_WA_Active
);

    wire Cimprec, WRSel, Dffwrb, DffC;
    wire [4:0] WL_auto;
    wire [7:0] SUM, CO;

    // FSM
    CIM_Control_Circuit ctrl_fsm (
        .clk(clk), .rst_n(rst_n), .MUL(MUL), .CIM(CIM),
        .Augend_addr(Augend_addr), .Addend_addr(Addend_addr), .Product_addr(Product_addr),
        .Cimprec(Cimprec), .WRSel(WRSel), .Dffwrb(Dffwrb), .DffC(DffC), .WL_auto(WL_auto)
    );

    // ALU
    rrcam_8bit alu (
        .CAND(SRAM_CAND), .CNOR(SRAM_CNOR), .CB(SRAM_CB),
        .SUM(SUM), .CO(CO)
    );

    // Write-back
    auto_switch_writeback_8bit wb_logic (
        .clk(clk), .rst_n(rst_n), .Cimprec(Cimprec), .WRSel(WRSel), .Is_Mul(MUL),
        .WL_auto(WL_auto), .SUM(SUM), .CO(CO), .Product(8'hA5), // 8'hA5 is dummy Product
        .CIM_Data(SRAM_CAND), .Write_Data_Bus(System_Data_Bus), .WL_out(System_WL_Out)
    );

    // SRAM
    SRAM_Control_Circuit sram_ctrl (
        .CLK(clk), .RST(!rst_n), .Word_addr(ext_word_addr), .Data(ext_write_data),
        .wr_en(ext_wr_en), .CIM(CIM|MUL), .WL_auto(WL_auto[2:0]), .WA(System_WA_Active)
    );
endmodule

// ============================================================
// 6. TESTBENCH
// ============================================================
module tb_CIM_System;
    reg clk, rst_n, MUL, CIM, ext_wr_en;
    reg [2:0] ext_word_addr;
    reg [7:0] ext_write_data;
    reg [4:0] Augend_addr, Addend_addr, Product_addr;
    reg [7:0] SRAM_CAND, SRAM_CNOR, SRAM_CB;

    wire [7:0] System_Data_Bus;
    wire [4:0] System_WL_Out;
    wire [7:0] System_WA_Active;

    CIM_Top_System dut (
        .clk(clk), .rst_n(rst_n), .MUL(MUL), .CIM(CIM),
        .ext_word_addr(ext_word_addr), .ext_write_data(ext_write_data), .ext_wr_en(ext_wr_en),
        .Augend_addr(Augend_addr), .Addend_addr(Addend_addr), .Product_addr(Product_addr),
        .SRAM_CAND(SRAM_CAND), .SRAM_CNOR(SRAM_CNOR), .SRAM_CB(SRAM_CB),
        .System_Data_Bus(System_Data_Bus), .System_WL_Out(System_WL_Out), .System_WA_Active(System_WA_Active)
    );

    always #5 clk = ~clk;

    initial begin
        // Initialize
        clk = 0; rst_n = 0; MUL = 0; CIM = 0; ext_wr_en = 0;
        ext_word_addr = 0; ext_write_data = 0;
        Augend_addr = 5'd1; Addend_addr = 5'd2; Product_addr = 5'd10;
        SRAM_CAND = 8'h05; SRAM_CNOR = 8'h0A; SRAM_CB = 8'h00;

        #20 rst_n = 1;
        #10 CIM = 1; // Trigger CIM Operation
        #100;
        $display("Test Complete. Data Bus: %h at Address: %d", System_Data_Bus, System_WL_Out);
        $finish;
    end
endmodule