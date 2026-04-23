
module cim_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        op_mul,
    input  wire        op_cim,

    input  wire [2:0]  aug_addr,
    input  wire [2:0]  add_addr,
    input  wire [2:0]  prod_addr,
    input  wire [2:0]  sign_addr,

    input  wire [2:0]  word_addr,
    input  wire [7:0]  data_in,
    input  wire        wr_en,

    input  wire [2:0]  bist_row,
    input  wire        bist_din,
    input  wire        bist_wr,

    output wire        data_out,
    output wire [7:0]  sum_out,
    output wire        co_out,
    output wire        sign_out,
    output wire        signprod_out,
    output wire        done
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    wire        dffwr, cimprec, wrsel, dffwrb, dffc;
    wire [2:0]  wl_aug, wl_add, bl_auto_fsm, s_addr_fsm;
    wire        is_mul, acc_clr;

    wire [2:0]  WS;
    wire [7:0]  WA_ctrl;        // combinational from sram_ctrl (FIX 1)
    wire [7:0]  WAB_ctrl;
    wire [7:0]  PRED;
    wire [7:0]  write_bus_ctrl;
    wire        wr_en_ctrl;

    wire [7:0]  wl_normal, wl_A, wl_B;
    wire [7:0]  BL, BL_A, BL_B;
    wire [7:0]  col_en;
    wire [7:0]  CAND, CNOR;
    wire [7:0]  SUM;
    wire        CO, SIGN, SIGNPROD;

    wire [7:0]  wb_wdata;
    wire [2:0]  wb_wl_out, wb_bl_out;
    wire        wb_wr_en;

    // =========================================================================
    // result_reg: captures SUM at EXECUTE (dffc pulse) so sum_out stays
    // valid and stable after the FSM moves on to WB / DONE states.
    // Without this, sum_out would follow the live adder output, which
    // computes garbage once wl_aug resets to 3'd0 in DONE.
    // =========================================================================
    reg [7:0] result_reg;
    reg       co_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_reg <= 8'h00;
            co_reg     <= 1'b0;
        end else if (dffc) begin
            result_reg <= SUM;
            co_reg     <= CO;
        end
    end

    assign sum_out      = result_reg;
    assign co_out       = co_reg;
    assign sign_out     = result_reg[7];
    assign signprod_out = SIGNPROD;

    // =========================================================================
    // Accumulator register
    //   acc_clr = 1  → ST_IDLE  → acc_reg = 0  (fresh MAC)
    //   dffc    = 1  → ST_EXEC  → acc_reg = SUM (enable chaining)
    //   else         → hold
    // When mac_chain() keeps op_cim=1, FSM goes DONE→READ (not IDLE),
    // so acc_clr never fires and acc_reg preserves SUM1 for MAC2.
    // =========================================================================
    reg [7:0] acc_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg <= 8'h00;
        end else if (acc_clr) begin
            acc_reg <= 8'h00;
        end else if (dffc) begin
            acc_reg <= SUM;
        end
    end

    // =========================================================================
    // Write arbitration: wb_circuit write-back wins over normal user write.
    // final_WA is combinational because WA_ctrl is now combinational (FIX 1).
    // =========================================================================
    wire        cim_active      = op_mul | op_cim;
    wire        final_wr_en     = wb_wr_en | wr_en_ctrl;
    wire [7:0]  final_WA        = wb_wr_en ? (8'h01 << wb_wl_out) : WA_ctrl;
    wire [7:0]  final_write_bus = wb_wr_en ? wb_wdata              : write_bus_ctrl;

    // =========================================================================
    // Submodule instantiations
    // =========================================================================

    cim_fsm u_fsm (
        .clk       (clk),
        .rst_n     (rst_n),
        .op_mul    (op_mul),
        .op_cim    (op_cim),
        .aug_addr  (aug_addr),
        .add_addr  (add_addr),
        .prod_addr (prod_addr),
        .sign_addr (sign_addr),
        .dffwr     (dffwr),
        .cimprec   (cimprec),
        .wrsel     (wrsel),
        .dffwrb    (dffwrb),
        .dffc      (dffc),
        .wl_aug    (wl_aug),
        .wl_add    (wl_add),
        .bl_auto   (bl_auto_fsm),
        .s_addr    (s_addr_fsm),
        .is_mul    (is_mul),
        .acc_clr   (acc_clr),
        .done      (done)
    );

    sram_ctrl u_sctrl (
        .clk        (clk),
        .rst_n      (rst_n),
        .cim_active (cim_active),
        .wl_auto    (wl_aug),
        .bl_auto    (bl_auto_fsm),
        .word_addr  (word_addr),
        .data_in    (data_in),
        .wr_en      (wr_en),
        .bist_row   (bist_row),
        .bist_din   (bist_din),
        .bist_wr    (bist_wr),
        .WS         (WS),
        .WA         (WA_ctrl),
        .WAB        (WAB_ctrl),
        .PRED       (PRED),
        .write_bus  (write_bus_ctrl),
        .wr_en_out  (wr_en_ctrl)
    );

    row_dec38 u_rdec_norm (.addr(WS),     .wl(wl_normal));
    row_dec38 u_rdec_A    (.addr(wl_aug), .wl(wl_A));
    row_dec38 u_rdec_B    (.addr(wl_add), .wl(wl_B));

    sram_8x8 u_sram (
        .clk       (clk),
        .rst_n     (rst_n),
        .WA        (final_WA),
        .write_bus (final_write_bus),
        .wr_en     (final_wr_en),
        .WL        (wl_normal),
        .BL        (BL),
        .WL_A      (wl_A),
        .BL_A      (BL_A),
        .WL_B      (wl_B),
        .BL_B      (BL_B)
    );

    col_dec38 u_cdec (.ws(WS), .col_en(col_en));

    col_sel u_csel (
        .bitlines (BL),
        .sel_en   (col_en),
        .data_out (data_out)
    );

    current_comp u_cc (
        .BL_A (BL_A),
        .BL_B (BL_B),
        .CAND (CAND),
        .CNOR (CNOR)
    );

    rrcam8 u_adder (
        .CAND     (CAND),
        .CNOR     (CNOR),
        .CB       (acc_reg),
        .SUM      (SUM),
        .CO       (CO),
        .SIGN     (SIGN),
        .SIGNPROD (SIGNPROD)
    );

    wb_circuit u_wb (
        .clk          (clk),
        .rst_n        (rst_n),
        .cimprec      (cimprec),
        .wrsel        (wrsel),
        .is_mul       (is_mul),
        .dffwrb       (dffwrb),
        .s_addr       (s_addr_fsm),
        .wl_auto      (wl_aug),
        .bl_auto      (bl_auto_fsm),
        .SUM          (SUM),
        .CO           (CO),
        .SIGNPROD     (SIGNPROD),
        .cim_data_bus ({5'h00, wl_aug}),
        .wdata        (wb_wdata),
        .wl_out       (wb_wl_out),
        .bl_out       (wb_bl_out),
        .wr_en_wb     (wb_wr_en)
    );

endmodule
// ========================= END cim_top.v =====================================
