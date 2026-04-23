
module sram_8x8 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  WA,
    input  wire [7:0]  write_bus,
    input  wire        wr_en,
    input  wire [7:0]  WL,
    output reg  [7:0]  BL,
    input  wire [7:0]  WL_A,
    output reg  [7:0]  BL_A,
    input  wire [7:0]  WL_B,
    output reg  [7:0]  BL_B
);
    reg [7:0] mem [0:7];
    integer   ii;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem[0] <= 8'h00; mem[1] <= 8'h00;
            mem[2] <= 8'h00; mem[3] <= 8'h00;
            mem[4] <= 8'h00; mem[5] <= 8'h00;
            mem[6] <= 8'h00; mem[7] <= 8'h00;
        end else if (wr_en) begin
            for (ii = 0; ii < 8; ii = ii + 1)
                if (WA[ii]) mem[ii] <= write_bus;
        end
    end

    always @(*) begin
        if      (WL[0]) BL = mem[0];
        else if (WL[1]) BL = mem[1];
        else if (WL[2]) BL = mem[2];
        else if (WL[3]) BL = mem[3];
        else if (WL[4]) BL = mem[4];
        else if (WL[5]) BL = mem[5];
        else if (WL[6]) BL = mem[6];
        else if (WL[7]) BL = mem[7];
        else             BL = 8'h00;
    end

    always @(*) begin
        if      (WL_A[0]) BL_A = mem[0];
        else if (WL_A[1]) BL_A = mem[1];
        else if (WL_A[2]) BL_A = mem[2];
        else if (WL_A[3]) BL_A = mem[3];
        else if (WL_A[4]) BL_A = mem[4];
        else if (WL_A[5]) BL_A = mem[5];
        else if (WL_A[6]) BL_A = mem[6];
        else if (WL_A[7]) BL_A = mem[7];
        else               BL_A = 8'h00;
    end

    always @(*) begin
        if      (WL_B[0]) BL_B = mem[0];
        else if (WL_B[1]) BL_B = mem[1];
        else if (WL_B[2]) BL_B = mem[2];
        else if (WL_B[3]) BL_B = mem[3];
        else if (WL_B[4]) BL_B = mem[4];
        else if (WL_B[5]) BL_B = mem[5];
        else if (WL_B[6]) BL_B = mem[6];
        else if (WL_B[7]) BL_B = mem[7];
        else               BL_B = 8'h00;
    end
endmodule


// ---------------------------------------------------------------------------
// Module 2 : row_dec38
// ---------------------------------------------------------------------------
module row_dec38 (
    input  wire [2:0] addr,
    output reg  [7:0] wl
);
    always @(*) begin
        case (addr)
            3'd0 : wl = 8'b0000_0001;
            3'd1 : wl = 8'b0000_0010;
            3'd2 : wl = 8'b0000_0100;
            3'd3 : wl = 8'b0000_1000;
            3'd4 : wl = 8'b0001_0000;
            3'd5 : wl = 8'b0010_0000;
            3'd6 : wl = 8'b0100_0000;
            3'd7 : wl = 8'b1000_0000;
            default : wl = 8'h00;
        endcase
    end
endmodule


// ---------------------------------------------------------------------------
// Module 3 : col_dec38
// ---------------------------------------------------------------------------
module col_dec38 (
    input  wire [2:0] ws,
    output reg  [7:0] col_en
);
    always @(*) begin
        case (ws)
            3'd0 : col_en = 8'b0000_0001;
            3'd1 : col_en = 8'b0000_0010;
            3'd2 : col_en = 8'b0000_0100;
            3'd3 : col_en = 8'b0000_1000;
            3'd4 : col_en = 8'b0001_0000;
            3'd5 : col_en = 8'b0010_0000;
            3'd6 : col_en = 8'b0100_0000;
            3'd7 : col_en = 8'b1000_0000;
            default : col_en = 8'h00;
        endcase
    end
endmodule


// ---------------------------------------------------------------------------
// Module 4 : col_sel
// ---------------------------------------------------------------------------
module col_sel (
    input  wire [7:0] bitlines,
    input  wire [7:0] sel_en,
    output wire       data_out
);
    assign data_out = |(bitlines & sel_en);
endmodule


// ---------------------------------------------------------------------------
// Module 5 : current_comp
// ---------------------------------------------------------------------------
module current_comp (
    input  wire [7:0] BL_A,
    input  wire [7:0] BL_B,
    output wire [7:0] CAND,
    output wire [7:0] CNOR
);
    assign CAND = BL_A & BL_B;
    assign CNOR = ~(BL_A | BL_B);
endmodule


// ---------------------------------------------------------------------------
// Module 6 : rrcam_cell
//   P = CAND ^ CNOR  (= XNOR(row_A[i], row_B[i]) since mutually exclusive)
//   SUM = P ^ CB ^ CI
//   CO  = (P & CB) | (CI & (P ^ CB))
// ---------------------------------------------------------------------------
module rrcam_cell (
    input  wire cand_i,
    input  wire cnor_i,
    input  wire cb_i,
    input  wire ci,
    output wire sum_o,
    output wire co_o
);
    wire p;
    assign p     = cand_i ^ cnor_i;
    assign sum_o = p ^ cb_i ^ ci;
    assign co_o  = (p & cb_i) | (ci & (p ^ cb_i));
endmodule


// ---------------------------------------------------------------------------
// Module 7 : rrcam8
// ---------------------------------------------------------------------------
module rrcam8 (
    input  wire [7:0] CAND,
    input  wire [7:0] CNOR,
    input  wire [7:0] CB,
    output wire [7:0] SUM,
    output wire       CO,
    output wire       SIGN,
    output wire       SIGNPROD
);
    wire [8:0] carry;
    assign carry[0] = 1'b0;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : GEN_RRCAM
            rrcam_cell u_cell (
                .cand_i (CAND[gi]),
                .cnor_i (CNOR[gi]),
                .cb_i   (CB[gi]),
                .ci     (carry[gi]),
                .sum_o  (SUM[gi]),
                .co_o   (carry[gi+1])
            );
        end
    endgenerate

    assign CO       = carry[8];
    assign SIGN     = SUM[7];
    assign SIGNPROD = CAND[7] ^ CB[7];
endmodule


// ---------------------------------------------------------------------------
// Module 8 : sram_ctrl   *** FIX 1 HERE ***
//
// WA and WAB are now COMBINATIONAL (wire, not reg).
// Previously they were registered (always @posedge), which meant WA lagged
// one cycle behind WS.  At the posedge when wr_en=1 fired, sram_8x8 saw
// the PREVIOUS cycle's WA — writing to the wrong row every time.
//
// PRED remains registered because it models a precharge settling time.
// ---------------------------------------------------------------------------
module sram_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cim_active,
    input  wire [2:0]  wl_auto,
    input  wire [2:0]  bl_auto,
    input  wire [2:0]  word_addr,
    input  wire [7:0]  data_in,
    input  wire        wr_en,
    input  wire [2:0]  bist_row,
    input  wire        bist_din,
    input  wire        bist_wr,
    output reg  [2:0]  WS,
    output wire [7:0]  WA,          // *** NOW wire (combinational) ***
    output wire [7:0]  WAB,         // *** NOW wire (combinational) ***
    output reg  [7:0]  PRED,
    output reg  [7:0]  write_bus,
    output reg         wr_en_out
);
    // Priority mux: CIM > BIST > Normal
    always @(*) begin
        if (cim_active) begin
            WS        = wl_auto;
            write_bus = 8'h00;
            wr_en_out = 1'b0;
        end else if (bist_wr) begin
            WS        = bist_row;
            write_bus = {8{bist_din}};
            wr_en_out = 1'b1;
        end else begin
            WS        = word_addr;
            write_bus = data_in;
            wr_en_out = wr_en;
        end
    end

    // *** FIXED: combinational one-hot decode — no pipeline delay ***
    assign WA  = (8'h01 << WS);
    assign WAB = ~(8'h01 << WS);

    // PRED remains registered (precharge settling indicator)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            PRED <= 8'hFF;
        end else begin
            PRED <= (wr_en_out | bist_wr) ? 8'h00 : 8'hFF;
        end
    end
endmodule


// ---------------------------------------------------------------------------
// Module 9 : cim_fsm   *** FIX 2 HERE ***
//
// ST_DONE now has two exit paths:
//   op_cim | op_mul asserted  → ST_READ  (chain next MAC, keep acc_reg)
//   op_cim & op_mul both low  → ST_IDLE  (done, clear acc_reg via acc_clr)
//
// Previously DONE only went to IDLE, so mac_chain() couldn't re-trigger
// without going through acc_clr.  The second MAC in the chain always started
// with CB=0 instead of CB=SUM1, giving 0xFF instead of 0xFE.
// ---------------------------------------------------------------------------
module cim_fsm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        op_mul,
    input  wire        op_cim,
    input  wire [2:0]  aug_addr,
    input  wire [2:0]  add_addr,
    input  wire [2:0]  prod_addr,
    input  wire [2:0]  sign_addr,
    output reg         dffwr,
    output reg         cimprec,
    output reg         wrsel,
    output reg         dffwrb,
    output reg         dffc,
    output reg  [2:0]  wl_aug,
    output reg  [2:0]  wl_add,
    output reg  [2:0]  bl_auto,
    output reg  [2:0]  s_addr,
    output reg         is_mul,
    output reg         acc_clr,
    output reg         done
);
    localparam [2:0]
        ST_IDLE = 3'd0,
        ST_READ = 3'd1,
        ST_EXEC = 3'd2,
        ST_WB   = 3'd3,
        ST_DONE = 3'd4;

    reg [2:0] state, nstate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= nstate;
    end

    always @(*) begin
        // --- Safe defaults (no latches) ---
        nstate  = state;
        dffwr   = 1'b0;
        cimprec = 1'b1;
        wrsel   = 1'b0;
        dffwrb  = 1'b0;
        dffc    = 1'b0;
        wl_aug  = 3'd0;
        wl_add  = 3'd0;
        bl_auto = 3'd0;
        s_addr  = 3'd0;
        is_mul  = op_mul;
        acc_clr = 1'b0;
        done    = 1'b0;

        case (state)
            // ---- IDLE: hold acc_reg = 0, wait for trigger ----
            ST_IDLE: begin
                acc_clr = 1'b1;
                if (op_mul | op_cim)
                    nstate = ST_READ;
            end

            // ---- READ_OPS: activate row addresses, strobe dffwr ----
            ST_READ: begin
                wl_aug = aug_addr;
                wl_add = add_addr;
                dffwr  = 1'b1;
                nstate = ST_EXEC;
            end

            // ---- EXECUTE: rows valid, adder stable, capture result ----
            ST_EXEC: begin
                wl_aug  = aug_addr;
                wl_add  = add_addr;
                dffc    = 1'b1;       // capture SUM into result_reg & acc_reg
                cimprec = ~op_mul;    // full precision for CIM, reduced for MUL
                nstate  = ST_WB;
            end

            // ---- WRITE_BACK: wb_circuit writes result to SRAM ----
            ST_WB: begin
                wrsel   = 1'b1;
                dffwrb  = 1'b1;
                s_addr  = op_mul ? sign_addr : prod_addr;
                wl_aug  = op_mul ? sign_addr : prod_addr;
                bl_auto = 3'd0;
                nstate  = ST_DONE;
            end

            // ---- DONE: signal completion ----
            // *** FIX 2: if op still asserted, re-trigger to ST_READ ***
            // *** (skip IDLE so acc_reg keeps SUM1 for chained MACs) ***
            // *** if op de-asserted, go to IDLE normally (acc_clr fires) ***
            ST_DONE: begin
                done = 1'b1;
                if (op_mul | op_cim)
                    nstate = ST_READ;   // *** NEW: chain without clearing acc ***
                else
                    nstate = ST_IDLE;   // normal single-MAC termination
            end

            default: nstate = ST_IDLE;
        endcase
    end
endmodule


// ---------------------------------------------------------------------------
// Module 10 : wb_circuit
// ---------------------------------------------------------------------------
module wb_circuit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cimprec,
    input  wire        wrsel,
    input  wire        is_mul,
    input  wire        dffwrb,
    input  wire [2:0]  s_addr,
    input  wire [2:0]  wl_auto,
    input  wire [2:0]  bl_auto,
    input  wire [7:0]  SUM,
    input  wire        CO,
    input  wire        SIGNPROD,
    input  wire [7:0]  cim_data_bus,
    output reg  [7:0]  wdata,
    output reg  [2:0]  wl_out,
    output reg  [2:0]  bl_out,
    output reg         wr_en_wb
);
    wire [7:0] arith;
    wire [7:0] next_data;

    assign arith     = is_mul  ? {7'h00, SIGNPROD} :
                       cimprec ? {CO, SUM[6:0]}     :
                                  SUM;
    assign next_data = wrsel ? arith : cim_data_bus;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wdata    <= 8'h00;
            wl_out   <= 3'd0;
            bl_out   <= 3'd0;
            wr_en_wb <= 1'b0;
        end else begin
            wr_en_wb <= 1'b0;           // default: de-assert (one-cycle pulse)
            if (dffwrb) begin
                wdata    <= next_data;
                wl_out   <= wrsel ? s_addr : wl_auto;
                bl_out   <= bl_auto;
                wr_en_wb <= 1'b1;
            end
        end
    end
endmodule
// ======================= END cim_submodules.v ================================
