// =============================================================================
// FILE : sim_main.cpp  (fixed)
//
// FIXES IN THIS VERSION:
//
// FIX 3 (mac() — de-assert op_cim BEFORE ticking out of DONE):
//   Previously: tick() was called first (with op_cim=1 still asserted),
//   THEN op_cim was de-asserted.  With the new DONE→READ FSM path, that
//   extra tick re-triggers a new unwanted MAC.
//   Fix: set op_cim=0, THEN tick() → FSM goes DONE→IDLE correctly.
//
// FIX 4 (mac_chain() — correctly chains two MACs via DONE→READ):
//   Previously mac_chain() called two separate _wait_done() loops with an
//   intervening tick(), but the FSM had no DONE→READ path so it sat in DONE.
//   Now: after MAC1 completes (state=DONE), keep op_cim=1, update addresses,
//   tick() once → FSM goes DONE→READ (new path, acc_reg preserved = SUM1),
//   then _wait_done() for MAC2.
//
// FIX 5 (TinyML demo write ordering):
//   Write weight to row n FIRST, then write input to scratch row 7.
//   This avoids the edge case where a wb_circuit write-back to row 6 shifts
//   the WA_ctrl value in the old registered version (now moot with FIX 1,
//   but explicit ordering is clearer and avoids any future regression).
//
// Build command:
//   verilator --cc --exe --build \
//     --Wno-WIDTHEXPAND --Wno-WIDTHTRUNC --Wno-UNUSED \
//     cim_submodules.v cim_top.v sim_main.cpp \
//     --top-module cim_top -o cim_sim
//   ./obj_dir/cim_sim
// =============================================================================

#include "Vcim_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cassert>
#include <vector>
#include <stdexcept>

#ifdef VL_TRACE
#include "verilated_vcd_c.h"
#endif

// =============================================================================
// CIMDriver
// =============================================================================
class CIMDriver {
public:
    Vcim_top*  dut;
    vluint64_t sim_time;

#ifdef VL_TRACE
    VerilatedVcdC* tfp;
#endif

    explicit CIMDriver(const char* vcd = nullptr) : sim_time(0) {
        dut = new Vcim_top();
#ifdef VL_TRACE
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC();
        dut->trace(tfp, 99);
        tfp->open(vcd ? vcd : "cim_trace.vcd");
#else
        (void)vcd;
#endif
        _clear_inputs();
        _do_reset();
    }

    ~CIMDriver() {
        dut->final();
#ifdef VL_TRACE
        if (tfp) { tfp->close(); delete tfp; }
#endif
        delete dut;
    }

    // ---- Clock primitives ----
    void _eval() {
        dut->eval();
#ifdef VL_TRACE
        tfp->dump(sim_time);
#endif
        sim_time++;
    }

    void tick() {
        dut->clk = 0; _eval();
        dut->clk = 1; _eval();
    }

    void _clear_inputs() {
        dut->clk=0; dut->rst_n=0;
        dut->op_mul=0; dut->op_cim=0;
        dut->aug_addr=0; dut->add_addr=0;
        dut->prod_addr=0; dut->sign_addr=0;
        dut->word_addr=0; dut->data_in=0; dut->wr_en=0;
        dut->bist_row=0; dut->bist_din=0; dut->bist_wr=0;
    }

    void _do_reset() {
        dut->rst_n = 0;
        for (int i = 0; i < 6; ++i) tick();
        dut->rst_n = 1;
        tick();
    }

    void reset() { _clear_inputs(); _do_reset(); }

    // ---- Poll done with timeout ----
    bool _wait_done(int max_cycles = 40) {
        for (int i = 0; i < max_cycles; ++i) {
            if (dut->done) return true;
            tick();
        }
        fprintf(stderr, "[WARN] _wait_done: timeout after %d cycles\n", max_cycles);
        return false;
    }

    // -------------------------------------------------------------------------
    // write_row: write 8-bit data to SRAM row via the normal user interface.
    //
    // With FIX 1 (combinational WA), writing is now 2 cycles:
    //   Cycle 1: word_addr + data_in + wr_en=1 asserted together.
    //            WA = (8'h01 << WS) is combinational, so at posedge the SRAM
    //            sees the correct WA and writes data.
    //   Cycle 2: wr_en de-asserted.
    // -------------------------------------------------------------------------
    void write_row(uint8_t row, uint8_t data) {
        assert(row < 8);
        dut->word_addr = row & 0x7;
        dut->data_in   = data;
        dut->wr_en     = 1;
        tick();             // posedge: SRAM writes data to correct row (WA combinational)
        dut->wr_en   = 0;
        dut->data_in = 0;
        tick();             // settle
    }

    // -------------------------------------------------------------------------
    // mac: single isolated XNOR-MAC.
    //   Returns XNOR(mem[aug], mem[add]) with acc_reg=0 (fresh from IDLE).
    //
    // FIX 3: op_cim is de-asserted BEFORE ticking out of DONE.
    //   Old sequence: tick() [re-triggers MAC!], op_cim=0, tick()
    //   New sequence: op_cim=0, tick() [DONE→IDLE, no re-trigger], tick()
    // -------------------------------------------------------------------------
    uint8_t mac(uint8_t aug, uint8_t add, uint8_t result_row) {
        assert(aug < 8 && add < 8 && result_row < 8);

        dut->aug_addr  = aug        & 0x7;
        dut->add_addr  = add        & 0x7;
        dut->prod_addr = result_row & 0x7;
        dut->op_cim    = 1;
        tick();                     // IDLE → READ_OPS

        _wait_done();               // READ → EXEC (captures result) → WB → DONE

        uint8_t result = static_cast<uint8_t>(dut->sum_out);

        // *** FIX 3: de-assert op_cim BEFORE ticking from DONE ***
        dut->op_cim = 0;
        tick();                     // DONE → IDLE  (SRAM write-back completes here)
        tick();                     // settle in IDLE (acc_clr fires, acc_reg=0)
        return result;
    }

    // -------------------------------------------------------------------------
    // mac_chain: two consecutive MACs with accumulator carry-over.
    //   MAC2's CB = MAC1's SUM (acc_reg preserved because IDLE is never entered).
    //
    // FIX 4: uses the new DONE→READ FSM path.
    //   After MAC1 completes (state=DONE), keep op_cim=1, update addresses,
    //   tick() → FSM: DONE→READ_OPS (acc_clr=0, acc_reg=SUM1).
    //   Then _wait_done() for MAC2 normally.
    //   At the end, op_cim=0 then tick() → DONE→IDLE.
    // -------------------------------------------------------------------------
    struct ChainResult { uint8_t r1; uint8_t r2; bool co2; };

    ChainResult mac_chain(uint8_t aug1, uint8_t add1,
                          uint8_t aug2, uint8_t add2,
                          uint8_t result_row) {
        assert(aug1<8 && add1<8 && aug2<8 && add2<8 && result_row<8);
        ChainResult cr;

        // ----- MAC 1 (starts from IDLE, acc_reg=0) -----
        dut->aug_addr  = aug1       & 0x7;
        dut->add_addr  = add1       & 0x7;
        dut->prod_addr = result_row & 0x7;
        dut->op_cim    = 1;
        tick();                     // IDLE → READ_OPS

        _wait_done();               // READ → EXEC → WB → DONE
        cr.r1 = static_cast<uint8_t>(dut->sum_out);
        // acc_reg now = SUM1 (captured at dffc in EXEC)

        // ----- MAC 2 (re-trigger from DONE, acc_reg=SUM1) -----
        // Keep op_cim=1, update operand addresses for second MAC
        dut->aug_addr = aug2 & 0x7;
        dut->add_addr = add2 & 0x7;
        // *** FIX 4: tick() with op_cim=1 in DONE → FSM: DONE→READ_OPS ***
        // SRAM write-back for MAC1 also completes at this posedge.
        tick();                     // DONE → READ_OPS

        _wait_done();               // READ → EXEC → WB → DONE
        cr.r2  = static_cast<uint8_t>(dut->sum_out);
        cr.co2 = dut->co_out != 0;

        // Terminate cleanly: de-assert first, then tick
        dut->op_cim = 0;
        tick();                     // DONE → IDLE  (MAC2 write-back completes)
        tick();                     // settle
        return cr;
    }

    // ---- MUL sign ----
    bool mul_sign(uint8_t aug, uint8_t add, uint8_t sign_row) {
        assert(aug < 8 && add < 8 && sign_row < 8);
        dut->aug_addr  = aug      & 0x7;
        dut->add_addr  = add      & 0x7;
        dut->sign_addr = sign_row & 0x7;
        dut->op_mul    = 1;
        tick();
        _wait_done();
        bool s = dut->signprod_out != 0;
        dut->op_mul = 0;
        tick();
        tick();
        return s;
    }

    // ---- BIST ----
    void bist_fill(uint8_t row, bool pattern) {
        assert(row < 8);
        dut->bist_row = row & 0x7;
        dut->bist_din = pattern ? 1 : 0;
        dut->bist_wr  = 1;
        tick();
        dut->bist_wr = 0;
        tick();
    }

    // ---- Getters ----
    uint8_t  read_sum()      const { return static_cast<uint8_t>(dut->sum_out); }
    bool     read_co()       const { return dut->co_out != 0; }
    bool     read_signprod() const { return dut->signprod_out != 0; }
    uint64_t cycles()        const { return sim_time / 2; }

    // ---- Batch layer MAC (for TinyML) ----
    std::vector<uint8_t> layer_mac(
        const std::vector<uint8_t>& weights,
        const std::vector<uint8_t>& inputs,
        uint8_t scratch = 7,
        uint8_t result  = 6)
    {
        size_t n = weights.size();
        if (n == 0 || n > 8) throw std::invalid_argument("need 1-8 weights");
        if (inputs.size() != n) throw std::invalid_argument("size mismatch");

        // FIX 5: write weights FIRST (rows 0..n-1), then compute per-neuron
        for (size_t i = 0; i < n; ++i)
            write_row(static_cast<uint8_t>(i), weights[i]);

        std::vector<uint8_t> out(n);
        for (size_t i = 0; i < n; ++i) {
            // Write input to scratch, then MAC with weight row i
            write_row(scratch, inputs[i]);
            out[i] = mac(static_cast<uint8_t>(i), scratch, result);
        }
        return out;
    }
};


// =============================================================================
// Software reference: XNOR of two bytes
// =============================================================================
static uint8_t xnor_ref(uint8_t a, uint8_t b) {
    return static_cast<uint8_t>(~(a ^ b));
}


// =============================================================================
// Self-test
// 8 isolated XNOR tests (each starts with acc_reg=0 via IDLE)
// + 1 chained accumulation test (acc_reg carries SUM1 into MAC2)
// =============================================================================
static int self_test() {
    printf("\n=== CIM Self-Test ===\n");
    CIMDriver hw;
    int pass = 0, fail = 0;

    // ---- 8 isolated XNOR tests ----
    struct TC { uint8_t a, b; const char* desc; };
    const TC cases[] = {
        {0xFF, 0xFF, "0xFF XNOR 0xFF -> 0xFF"},
        {0x00, 0x00, "0x00 XNOR 0x00 -> 0xFF"},
        {0xFF, 0x00, "0xFF XNOR 0x00 -> 0x00"},
        {0xAA, 0x55, "0xAA XNOR 0x55 -> 0x00"},
        {0xAA, 0xAA, "0xAA XNOR 0xAA -> 0xFF"},
        {0xF0, 0x0F, "0xF0 XNOR 0x0F -> 0x00"},
        {0xA5, 0xA5, "0xA5 XNOR 0xA5 -> 0xFF"},
        {0x12, 0x21, "0x12 XNOR 0x21 -> 0xCC"},
    };

    for (int t = 0; t < 8; ++t) {
        hw.write_row(0, cases[t].a);
        hw.write_row(1, cases[t].b);
        uint8_t got = hw.mac(0, 1, 2);
        uint8_t exp = xnor_ref(cases[t].a, cases[t].b);
        bool ok = (got == exp);
        ok ? ++pass : ++fail;
        printf("  [%s] %s  hw=0x%02X exp=0x%02X\n",
               ok ? "PASS" : "FAIL", cases[t].desc, got, exp);
    }

    // ---- Chained accumulation test ----
    // MAC1: XNOR(0xFF,0xFF) + CB(0x00) = 0xFF + 0x00 = 0xFF, CO=0
    // MAC2: XNOR(0xFF,0xFF) + CB(0xFF) = 0xFF + 0xFF = 0xFE, CO=1
    printf("  --- Chained accumulation test ---\n");
    hw.write_row(0, 0xFF);
    hw.write_row(1, 0xFF);
    CIMDriver::ChainResult cr = hw.mac_chain(0, 1, 0, 1, 2);
    bool ok1 = (cr.r1 == 0xFF);
    bool ok2 = (cr.r2 == 0xFE && cr.co2);
    ok1 ? ++pass : ++fail;
    ok2 ? ++pass : ++fail;
    printf("  [%s] MAC1 (CB=0x00): XNOR(0xFF,0xFF)+0x00 = 0x%02X  exp=0xFF\n",
           ok1 ? "PASS" : "FAIL", cr.r1);
    printf("  [%s] MAC2 (CB=0xFF): XNOR(0xFF,0xFF)+0xFF = 0x%02X  CO=%d  exp=0xFE CO=1\n",
           ok2 ? "PASS" : "FAIL", cr.r2, (int)cr.co2);

    printf("Self-test: %d/%d passed  (%d failures)\n", pass, pass + fail, fail);
    return fail;
}


// =============================================================================
// TinyML 8-neuron layer demo
// FIX 5: weight written BEFORE input to avoid any ordering sensitivity.
// =============================================================================
static int tinyml_demo() {
    printf("\n=== TinyML 8-Neuron Layer Demo ===\n");
    CIMDriver hw;

    const uint8_t weights[8] = {
        0b11001100,   // w0
        0b10101010,   // w1
        0b11110000,   // w2
        0b00001111,   // w3
        0b01010101,   // w4
        0b11111111,   // w5
        0b00000000,   // w6
        0b10011001    // w7
    };
    const uint8_t inputs[8] = {
        0b11001100,   // x0  -> XNOR(w0,x0) = 0xFF
        0b01010101,   // x1  -> XNOR(w1,x1) = 0x00
        0b11110000,   // x2  -> XNOR(w2,x2) = 0xFF
        0b11110000,   // x3  -> XNOR(w3,x3) = 0x00
        0b10101010,   // x4  -> XNOR(w4,x4) = 0x00
        0b11111111,   // x5  -> XNOR(w5,x5) = 0xFF
        0b11111111,   // x6  -> XNOR(w6,x6) = 0x00
        0b10011001    // x7  -> XNOR(w7,x7) = 0xFF
    };

    printf("  %-8s %-10s %-10s %-8s %-8s %-6s\n",
           "Neuron","Weight","Input","HW","REF","Match");

    int mismatches = 0;
    for (int n = 0; n < 8; ++n) {
        // FIX 5: write weight first, then input to scratch row 7
        hw.write_row(static_cast<uint8_t>(n), weights[n]);   // weight → row n
        hw.write_row(7, inputs[n]);                           // input  → scratch 7
        uint8_t got = hw.mac(static_cast<uint8_t>(n), 7, 6);
        uint8_t ref = xnor_ref(weights[n], inputs[n]);
        bool match  = (got == ref);
        if (!match) ++mismatches;
        printf("  %-8d 0x%02X       0x%02X       0x%02X    0x%02X    %s\n",
               n, weights[n], inputs[n], got, ref, match ? "OK" : "MISMATCH");
    }
    printf("TinyML demo: %d/%d correct\n", 8 - mismatches, 8);
    return mismatches;
}


// =============================================================================
// main
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    printf("============================================================\n");
    printf("  CIM MAC Core — Verilator C++ Simulation\n");
    printf("  8x8 SRAM | FS-GDI Adder | XNOR-Popcount MAC\n");
    printf("============================================================\n");

    int test_fails = self_test();
    int demo_fails = tinyml_demo();

    printf("\n============================================================\n");
    printf("  Self-test failures : %d\n", test_fails);
    printf("  TinyML mismatches  : %d\n", demo_fails);
    printf("  Overall status     : %s\n",
           (test_fails + demo_fails == 0) ? "ALL PASS" : "SOME FAILURES");
    printf("============================================================\n");

    return (test_fails + demo_fails == 0) ? 0 : 1;
}
// ========================= END sim_main.cpp ==================================