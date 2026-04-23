#include <pybind11/pybind11.h>
#include <pybind11/stl.h>
#include <pybind11/numpy.h>
#include <vector>
#include <cstdint>
#include <stdexcept>
#include <string>

#define PYBIND_BUILD
#include "Vcim_top.h"
#include "verilated.h"

// =============================================================================
// CIMDriver  —  synced with sim_main.cpp (FIX 3 applied)
//
// FIX 3  (mac / mul_sign  — de-assert op signal BEFORE settling ticks)
//   Old sequence:  tick() [op asserted → FSM DONE→READ re-trigger!], op=0, tick()
//   New sequence:  op=0,  tick() [FSM DONE→IDLE cleanly],            tick()
//
//   Root cause: cim_fsm ST_DONE has a DONE→READ fast-path when op_cim|op_mul=1
//   (intended for mac_chain).  The old code left op_cim=1 during the first
//   settling tick, so every single mac() call silently launched a second
//   phantom MAC.  For Test 1 (0xFF XNOR 0xFF) the phantom output was still
//   0xFF so the bug was invisible; for Test 2 (0xFF XNOR 0x00) the phantom
//   run started with acc_reg=SUM1 and corrupted the result to 0xFF.
// =============================================================================
class CIMDriver {
public:
    Vcim_top*  dut;
    vluint64_t sim_time;

    explicit CIMDriver() : sim_time(0) {
        dut = new Vcim_top();
        _clear_inputs();
        _do_reset();
    }

    ~CIMDriver() { dut->final(); delete dut; }

    void _eval() { dut->eval(); sim_time++; }

    void tick() {
        dut->clk = 0; _eval();
        dut->clk = 1; _eval();
    }

    void _clear_inputs() {
        dut->clk=0; dut->rst_n=0; dut->op_mul=0; dut->op_cim=0;
        dut->aug_addr=0; dut->add_addr=0; dut->prod_addr=0; dut->sign_addr=0;
        dut->word_addr=0; dut->data_in=0; dut->wr_en=0;
        dut->bist_row=0; dut->bist_din=0; dut->bist_wr=0;
    }

    void _do_reset() {
        dut->rst_n = 0;
        for (int i = 0; i < 4; ++i) tick();
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
        return false;
    }

    void write_row(uint8_t row, uint8_t data) {
        if (row >= 8) throw std::out_of_range("row must be 0-7");
        dut->word_addr = row; dut->data_in = data; dut->wr_en = 1;
        tick();
        dut->wr_en = 0; dut->data_in = 0;
        tick();
    }

    // -------------------------------------------------------------------------
    // mac  —  single isolated XNOR-MAC (acc_reg starts at 0 from IDLE).
    //
    // FIX 3: de-assert op_cim BEFORE the settling tick so the FSM takes the
    // DONE→IDLE path, not the DONE→READ chain path.
    // -------------------------------------------------------------------------
    uint8_t mac(uint8_t aug, uint8_t add, uint8_t result_row) {
        if (aug >= 8 || add >= 8 || result_row >= 8)
            throw std::out_of_range("address must be 0-7");

        dut->aug_addr  = aug;
        dut->add_addr  = add;
        dut->prod_addr = result_row;
        dut->op_cim    = 1;
        tick();                   // IDLE → READ_OPS

        _wait_done();             // READ → EXEC → WB → DONE

        // *** FIX 3: de-assert BEFORE ticking out of DONE ***
        dut->op_cim = 0;
        uint8_t result = (uint8_t)dut->sum_out;
        tick();                   // DONE → IDLE  (write-back completes here)
        tick();                   // settle in IDLE (acc_clr fires → acc_reg=0)
        return result;
    }

    // -------------------------------------------------------------------------
    // mul_sign  —  same fix applied.
    // -------------------------------------------------------------------------
    bool mul_sign(uint8_t aug, uint8_t add, uint8_t sign_row) {
        if (aug >= 8 || add >= 8 || sign_row >= 8)
            throw std::out_of_range("address must be 0-7");

        dut->aug_addr  = aug;
        dut->add_addr  = add;
        dut->sign_addr = sign_row;
        dut->op_mul    = 1;
        tick();
        _wait_done();

        bool s = dut->signprod_out != 0;

        // *** FIX 3 (mul variant): de-assert BEFORE settling ticks ***
        dut->op_mul = 0;
        tick();
        tick();
        return s;
    }

    void bist_fill(uint8_t row, bool pattern) {
        if (row >= 8) throw std::out_of_range("row must be 0-7");
        dut->bist_row = row; dut->bist_din = pattern ? 1 : 0; dut->bist_wr = 1;
        tick(); dut->bist_wr = 0; tick();
    }

    uint8_t  read_sum()      const { return (uint8_t)dut->sum_out; }
    bool     read_co()       const { return dut->co_out != 0; }
    bool     read_signprod() const { return dut->signprod_out != 0; }
    uint64_t cycles()        const { return sim_time / 2; }

    // ---- Batch MAC for TinyML layer ----
    std::vector<uint8_t> layer_mac(
        const std::vector<uint8_t>& weights,
        const std::vector<uint8_t>& inputs,
        uint8_t scratch_row = 7,
        uint8_t result_row  = 6)
    {
        size_t n = weights.size();
        if (n == 0 || n > 8) throw std::invalid_argument("weights: 1-8 rows");
        if (inputs.size() != n) throw std::invalid_argument("inputs size mismatch");

        for (size_t i = 0; i < n; ++i)
            write_row((uint8_t)i, weights[i]);

        std::vector<uint8_t> out(n);
        for (size_t i = 0; i < n; ++i) {
            write_row(scratch_row, inputs[i]);
            out[i] = mac((uint8_t)i, scratch_row, result_row);
        }
        return out;
    }
};

// =============================================================================
// pybind11 module definition
// =============================================================================
namespace py = pybind11;

PYBIND11_MODULE(cim_hw, m) {
    m.doc() = "CIM MAC Hardware Accelerator — Verilated XNOR-popcount engine";

    py::class_<CIMDriver>(m, "CIMHardware")
        .def(py::init<>(), "Create and reset the CIM hardware instance.")

        .def("reset", &CIMDriver::reset,
             "Assert hardware reset and return to IDLE state.")

        .def("write_row", &CIMDriver::write_row,
             py::arg("row"), py::arg("data"),
             "Write an 8-bit value to SRAM row [0-7].\n"
             "Args:\n"
             "  row  : SRAM row index (0-7)\n"
             "  data : 8-bit value to store")

        .def("mac", &CIMDriver::mac,
             py::arg("aug"), py::arg("add"), py::arg("result_row"),
             "Perform one CIM XNOR-MAC operation.\n"
             "Computes XNOR(mem[aug], mem[add]) + accumulator,\n"
             "writes result to mem[result_row], returns 8-bit SUM.\n"
             "Args:\n"
             "  aug        : augend row address (0-7)\n"
             "  add        : addend row address (0-7)\n"
             "  result_row : destination row for result (0-7)")

        .def("mul_sign", &CIMDriver::mul_sign,
             py::arg("aug"), py::arg("add"), py::arg("sign_row"),
             "Compute product sign bit and write to sign_row.\n"
             "Returns bool signprod = CAND[7] XOR CB[7].")

        .def("bist_fill", &CIMDriver::bist_fill,
             py::arg("row"), py::arg("pattern"),
             "BIST fill: write 0x00 (pattern=False) or 0xFF (pattern=True) to row.")

        .def("read_sum",      &CIMDriver::read_sum,
             "Return current 8-bit adder SUM (combinational, no clock tick).")
        .def("read_co",       &CIMDriver::read_co,
             "Return current carry-out bit.")
        .def("read_signprod", &CIMDriver::read_signprod,
             "Return current product-sign bit.")
        .def("cycles",        &CIMDriver::cycles,
             "Return total simulated clock cycles since construction.")

        .def("layer_mac", &CIMDriver::layer_mac,
             py::arg("weights"),
             py::arg("inputs"),
             py::arg("scratch_row") = 7,
             py::arg("result_row")  = 6,
             "Run a full linear layer MAC on the hardware.\n"
             "Args:\n"
             "  weights    : list of up to 8 uint8 weight values\n"
             "  inputs     : list of uint8 input activations (same length)\n"
             "  scratch_row: SRAM row used for input loading (default 7)\n"
             "  result_row : SRAM row for intermediate results (default 6)\n"
             "Returns list of uint8 XNOR-MAC outputs.");
}
// ========================= END cim_pybind.cpp ================================