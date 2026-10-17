`timescale 1ns / 1ps

module tb_vector_compute_unit;

    reg          clk;
    reg          rst_n;
    reg  [3:0]   opcode;
    reg          sew;
    reg  [3:0]   v0_mask;
    reg  [127:0] vs1;
    reg  [127:0] vs2;
    reg  [127:0] old_vd;
    
    wire [127:0] vd_out;
    wire         valid_out;

    // Instantiate Top-Level VCU
    vector_compute_unit uut (
        .clk(clk),
        .rst_n(rst_n),
        .opcode(opcode),
        .sew(sew),
        .v0_mask(v0_mask),
        .vs1(vs1),
        .vs2(vs2),
        .old_vd(old_vd),
        .vd_out(vd_out),
        .valid_out(valid_out)
    );

    // Clock Generation
    always #5 clk = ~clk;

    // Checker Task
    task check_vector;
        input [127:0] expected;
        input [120:0] test_name;
        begin
            @(posedge clk);
            #1; // Pipeline delay
            if (vd_out !== expected) begin
                $display("[FAIL] %s\n  Expected: %h\n  Got:      %h", test_name, expected, vd_out);
                $stop;
            end else begin
                $display("[PASS] %s", test_name);
            end
        end
    endtask

    initial begin
        // Reset and Initialization
        clk = 0; rst_n = 0; v0_mask = 4'b1111; sew = 1; 
        opcode = 0; vs1 = 0; vs2 = 0; old_vd = 128'hDEADBEEF_DEADBEEF_DEADBEEF_DEADBEEF;
        
        #15 rst_n = 1;

        // ---------------------------------------------------------
        // TEST 1: 32-bit Vector Addition (All Lanes Active)
        // ---------------------------------------------------------
        opcode = 4'd2; // OP_VUADD
        sew    = 1'b1; // 32-bit
        v0_mask = 4'b1111;
        // Load 4 independent 32-bit integers into vs1 and vs2
        vs1 = {32'd40, 32'd30, 32'd20, 32'd10};
        vs2 = {32'd4,  32'd3,  32'd2,  32'd1};
        check_vector({32'd44, 32'd33, 32'd22, 32'd11}, "TEST 1: 32-bit Vector Add (4 Elements)");

        // ---------------------------------------------------------
        // TEST 2: 32-bit FP Addition (All Lanes Active)
        // ---------------------------------------------------------
        opcode = 4'd8; // OP_FADD
        // 2.0 (40000000) + 3.0 (40400000) = 5.0 (40A00000) across all 4 lanes
        vs1 = {32'h40000000, 32'h40000000, 32'h40000000, 32'h40000000};
        vs2 = {32'h40400000, 32'h40400000, 32'h40400000, 32'h40400000};
        check_vector({32'h40A00000, 32'h40A00000, 32'h40A00000, 32'h40A00000}, "TEST 2: 32-bit FP Vector Add");

        // ---------------------------------------------------------
        // TEST 3: Hardware Masking Logic (v0 register)
        // ---------------------------------------------------------
        opcode = 4'd0; // OP_VAND
        v0_mask = 4'b1010; // Only lanes 3 and 1 will update. Lanes 2 and 0 retain old_vd.
        vs1 = {32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF, 32'hFFFFFFFF};
        vs2 = {32'h00000000, 32'h00000000, 32'h00000000, 32'h00000000};
        // Expected: Lane 3 (00000000), Lane 2 (DEADBEEF), Lane 1 (00000000), Lane 0 (DEADBEEF)
        check_vector({32'h00000000, 32'hDEADBEEF, 32'h00000000, 32'hDEADBEEF}, "TEST 3: V0 Register Masking");

        // ---------------------------------------------------------
        // TEST 4: 16-bit Vector Multiplication (FP16)
        // ---------------------------------------------------------
        opcode = 4'd10; // OP_FMUL
        sew    = 1'b0;  // Switch SEW to 16-bit mode
        v0_mask = 4'b1111;
        // 2.0 (4000) * 3.0 (4200) = 6.0 (4600)
        // Packing four 16-bit elements into the lower 64 bits of the 128-bit bus
        vs1 = {64'd0, 16'h4000, 16'h4000, 16'h4000, 16'h4000};
        vs2 = {64'd0, 16'h4200, 16'h4200, 16'h4200, 16'h4200};
        check_vector({64'd0, 16'h4600, 16'h4600, 16'h4600, 16'h4600}, "TEST 4: 16-bit FP Vector Multiply");

        $display("ALL SIMD SYSTEM TESTS PASSED.");
        $finish;
    end
endmodule
