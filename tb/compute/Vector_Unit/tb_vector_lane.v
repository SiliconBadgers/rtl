`timescale 1ns / 1ps

module tb_vector_lane;

    reg clk;
    reg rst_n;
    reg [3:0] opcode;
    reg sew;
    reg mask;
    reg [31:0] in_a;
    reg [31:0] in_b;
    reg [31:0] old_vd;
    
    wire [31:0] out_vd;
    wire valid_out;

    // Instantiate Lane
    vector_lane_compute uut (
        .clk(clk),
        .rst_n(rst_n),
        .opcode(opcode),
        .sew(sew),
        .mask(mask),
        .in_a(in_a),
        .in_b(in_b),
        .old_vd(old_vd),
        .out_vd(out_vd),
        .valid_out(valid_out)
    );

    // Clock gen
    always #5 clk = ~clk;

    // Every check below must run; a short count fails the test.
    localparam EXPECTED_CHECKS = 14;
    integer checks;
    integer errors;

    // Checker Task
    task check_res;
        input [31:0] expected;
        input [8*32-1:0] op_name; // String identifier (up to 32 chars)
        begin
            @(posedge clk);
            #1; // Wait for writeback pipeline delay
            checks = checks + 1;
            if (out_vd !== expected) begin
                errors = errors + 1;
                $display("[FAIL] %0s: Expected %h, Got %h", op_name, expected, out_vd);
            end else begin
                $display("[PASS] %0s: Got %h", op_name, out_vd);
            end
        end
    endtask

    initial begin
        // Initialize
        clk = 0; rst_n = 0; mask = 1; old_vd = 32'hDEADBEEF; sew = 1;
        in_a = 0; in_b = 0; opcode = 0; checks = 0; errors = 0;

        #10 rst_n = 1;

        // 1. Bitwise AND
        opcode = 4'd0; in_a = 32'hFF00FF00; in_b = 32'hF0F0F0F0;
        check_res(32'hF000F000, "VAND");

        // 2. Unsigned Saturation Add (No Overflow vs Overflow)
        opcode = 4'd2; in_a = 32'h00000005; in_b = 32'h00000005; check_res(32'h0000000A, "VUADD Normal");
        opcode = 4'd2; in_a = 32'hFFFFFFF0; in_b = 32'h00000020; check_res(32'hFFFFFFFF, "VUADD Saturate");

        // 3. Signed Saturation Sub (Underflow check)
        opcode = 4'd3; in_a = 32'h80000005; in_b = 32'h00000010; check_res(32'h80000000, "VSSUB Sat Neg");

        // 4. Shifts (VSLL, VSRL, VSRA)
        opcode = 4'd5; in_a = 32'h00000001; in_b = 32'd4; check_res(32'h00000010, "VSLL");
        opcode = 4'd6; in_a = 32'hF0000000; in_b = 32'd4; check_res(32'h0F000000, "VSRL Unsigned");
        opcode = 4'd7; in_a = 32'hF0000000; in_b = 32'd4; check_res(32'hFF000000, "VSRA Signed");

        // 5. Masking Logic
        mask = 0; opcode = 4'd0; in_a = 32'hFFFFFFFF; in_b = 32'hFFFFFFFF; 
        check_res(32'hDEADBEEF, "Mask=0 Check");
        mask = 1;

        // 6. FP32 Addition (2.0 + 3.0 = 5.0)
        // 2.0 = 40000000, 3.0 = 40400000, 5.0 = 40A00000
        sew = 1; opcode = 4'd8; 
        in_a = 32'h40000000; in_b = 32'h40400000; 
        check_res(32'h40A00000, "FADD32 (2.0+3.0=5.0)");

        // 7. FP32 Subtraction (5.0 - 3.0 = 2.0)
        opcode = 4'd9; 
        in_a = 32'h40A00000; in_b = 32'h40400000; 
        check_res(32'h40000000, "FSUB32 (5.0-3.0=2.0)");

        // 8. FP32 Multiplication (2.0 * 3.0 = 6.0)
        // 6.0 = 40C00000
        opcode = 4'd10; 
        in_a = 32'h40000000; in_b = 32'h40400000; 
        check_res(32'h40C00000, "FMUL32 (2.0*3.0=6.0)");

        // 9. FP16 Addition (2.0 + 3.0 = 5.0 in Float16)
        // 2.0 = 4000, 3.0 = 4200, 5.0 = 4500
        sew = 0; opcode = 4'd8; 
        in_a = {16'b0, 16'h4000}; in_b = {16'b0, 16'h4200}; 
        check_res(32'h00004500, "FADD16 (2.0+3.0=5.0)");

        // 10. FP16 Subtraction (5.0 - 3.0 = 2.0 in Float16)
        opcode = 4'd9;
        in_a = {16'b0, 16'h4500}; in_b = {16'b0, 16'h4200};
        check_res(32'h00004000, "FSUB16 (5.0-3.0=2.0)");

        // 11. FP16 Multiplication (2.0 * 3.0 = 6.0 in Float16)
        // 6.0 = 4600
        opcode = 4'd10;
        in_a = {16'b0, 16'h4000}; in_b = {16'b0, 16'h4200};
        check_res(32'h00004600, "FMUL16 (2.0*3.0=6.0)");

        $display("RESULT tb_vector_lane checks=%0d expected=%0d errors=%0d status=%0s",
                 checks, EXPECTED_CHECKS, errors,
                 (errors == 0 && checks == EXPECTED_CHECKS) ? "PASS" : "FAIL");
        if (errors != 0 || checks != EXPECTED_CHECKS)
            $fatal(1, "tb_vector_lane: FAIL (%0d errors, %0d of %0d checks run)",
                   errors, checks, EXPECTED_CHECKS);
        $finish;
    end
endmodule
