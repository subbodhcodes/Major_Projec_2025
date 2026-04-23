import cim_hw
import sys

def run_smoke_test():
    try:
        # Initialize the hardware
        hw = cim_hw.CIMHardware()
        print("--- CIM Hardware Smoke Test Starting ---")

        # In your C++ code, mac() requires (aug, add, result_row)
        # We will use '2' as a dummy result_row for these tests
        
        # Test 1: Identical rows
        hw.write_row(0, 0xFF)
        hw.write_row(1, 0xFF)
        # Added the 3rd argument '2' here
        result_match = hw.mac(0, 1, 2) 
        
        print(f"Test 1 (Identical): Sent 0xFF & 0xFF | Received: {hex(result_match)}")
        assert result_match == 0xFF, f"Match failed: Expected 0xFF, got {hex(result_match)}"

        # Test 2: Complementary rows
        hw.write_row(0, 0xFF)
        hw.write_row(1, 0x00)
        # Added the 3rd argument '2' here
        result_mismatch = hw.mac(0, 1, 2)
        
        print(f"Test 2 (Complementary): Sent 0xFF & 0x00 | Received: {hex(result_mismatch)}")
        assert result_mismatch == 0x00, f"Mismatch failed: Expected 0x00, got {hex(result_mismatch)}"

        print("-" * 40)
        print("SUCCESS: All tests passed!")
        print(f"Total Simulation Cycles: {hw.cycles()}")
        print("-" * 40)

    except AssertionError as e:
        print(f"FAILURE: {e}")
        sys.exit(1)
    except TypeError as e:
        print(f"ARGUMENT ERROR: {e}")
        sys.exit(1)

if __name__ == "__main__":
    run_smoke_test()