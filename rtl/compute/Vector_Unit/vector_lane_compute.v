`timescale 1ns / 1ps

module vector_lane_compute (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  opcode,
    input  wire        sew,       // 0 = 16-bit, 1 = 32-bit (for FP)
    input  wire        mask,      // 1 = execute, 0 = keep old val
    input  wire [31:0] in_a,
    input  wire [31:0] in_b,
    input  wire [31:0] old_vd,    // Previous destination value (for masking)
    output reg  [31:0] out_vd,
    output reg         valid_out
);

    // Opcode Definitions
    localparam OP_VAND   = 4'd0;
    localparam OP_VSADD  = 4'd1;  // Signed Saturation Add
    localparam OP_VUADD  = 4'd2;  // Unsigned Saturation Add
    localparam OP_VSSUB  = 4'd3;  // Signed Saturation Sub
    localparam OP_VUSUB  = 4'd4;  // Unsigned Saturation Sub
    localparam OP_VSLL   = 4'd5;  // Shift Left Logical
    localparam OP_VSRL   = 4'd6;  // Shift Right Logical (Unsigned)
    localparam OP_VSRA   = 4'd7;  // Shift Right Arithmetic (Signed)
    localparam OP_FADD   = 4'd8;  // FP Add
    localparam OP_FSUB   = 4'd9;  // FP Sub
    localparam OP_FMUL   = 4'd10; // FP Mul

    // Internal Combinational Results
    reg [31:0] int_res;
    reg [31:0] fp_res;
    reg [31:0] final_res;

    // -------------------------------------------------------------------------
    // INTEGER & BITWISE LOGIC
    // -------------------------------------------------------------------------
    wire [32:0] sum_signed    = {in_a[31], in_a} + {in_b[31], in_b};
    wire [32:0] sub_signed    = {in_a[31], in_a} - {in_b[31], in_b};
    wire [32:0] sum_unsigned  = {1'b0, in_a} + {1'b0, in_b};
    wire [32:0] sub_unsigned  = {1'b0, in_a} - {1'b0, in_b};
    
    wire signed [31:0] in_a_signed = in_a;
    wire [4:0] shamt = in_b[4:0];

    always @(*) begin
        int_res = 32'd0;
        case (opcode)
            OP_VAND: int_res = in_a & in_b;
            OP_VSLL: int_res = in_a << shamt;
            OP_VSRL: int_res = in_a >> shamt;
            OP_VSRA: int_res = in_a_signed >>> shamt;
            
            OP_VSADD: begin
                if (~in_a[31] && ~in_b[31] && sum_signed[31]) // Pos + Pos = Neg (Overflow)
                    int_res = 32'h7FFFFFFF;
                else if (in_a[31] && in_b[31] && ~sum_signed[31]) // Neg + Neg = Pos (Underflow)
                    int_res = 32'h80000000;
                else
                    int_res = sum_signed[31:0];
            end
            
            OP_VUADD: begin
                if (sum_unsigned[32]) int_res = 32'hFFFFFFFF;
                else int_res = sum_unsigned[31:0];
            end
            
            OP_VSSUB: begin
                if (~in_a[31] && in_b[31] && sub_signed[31]) // Pos - Neg = Neg (Overflow)
                    int_res = 32'h7FFFFFFF;
                else if (in_a[31] && ~in_b[31] && ~sub_signed[31]) // Neg - Pos = Pos (Underflow)
                    int_res = 32'h80000000;
                else
                    int_res = sub_signed[31:0];
            end
            
            OP_VUSUB: begin
                if (sub_unsigned[32]) int_res = 32'h00000000; // Underflow sets to 0
                else int_res = sub_unsigned[31:0];
            end
            default: int_res = 32'd0;
        endcase
    end

    // -------------------------------------------------------------------------
    // FLOATING POINT LOGIC (Explicit Bit-Level FADD/FSUB/FMUL)
    // -------------------------------------------------------------------------
    // Unpack Logic based on SEW (0 = FP16, 1 = FP32)
    wire        sign_a = sew ? in_a[31] : in_a[15];
    wire        sign_b = sew ? (opcode == OP_FSUB ? ~in_b[31] : in_b[31]) : 
                               (opcode == OP_FSUB ? ~in_b[15] : in_b[15]);
    
    wire [7:0]  exp_a  = sew ? in_a[30:23] : {3'b0, in_a[14:10]};
    wire [7:0]  exp_b  = sew ? in_b[30:23] : {3'b0, in_b[14:10]};
    wire [7:0]  bias   = sew ? 8'd127 : 8'd15;
    
    wire [23:0] mant_a = sew ? { (exp_a != 0), in_a[22:0] } : {14'b0, (exp_a != 0), in_a[9:0]};
    wire [23:0] mant_b = sew ? { (exp_b != 0), in_b[22:0] } : {14'b0, (exp_b != 0), in_b[9:0]};

    // FP ADDER DATAPATH
    reg [7:0]  add_exp;
    reg [24:0] add_mant_shifted_a, add_mant_shifted_b;
    reg [24:0] add_mant_res;
    reg        add_sign;
    reg [7:0]  exp_diff;
    reg [23:0] norm_mant;
    reg [7:0]  norm_exp;
    integer    i;

    always @(*) begin
        // 1. Exponent Alignment
        if (exp_a > exp_b) begin
            add_exp = exp_a;
            exp_diff = exp_a - exp_b;
            add_mant_shifted_a = {1'b0, mant_a};
            add_mant_shifted_b = {1'b0, mant_b} >> exp_diff;
            add_sign = sign_a;
        end else begin
            add_exp = exp_b;
            exp_diff = exp_b - exp_a;
            add_mant_shifted_a = {1'b0, mant_a} >> exp_diff;
            add_mant_shifted_b = {1'b0, mant_b};
            add_sign = sign_b;
        end

        // 2. Mantissa Math
        if (sign_a == sign_b) begin
            add_mant_res = add_mant_shifted_a + add_mant_shifted_b;
            add_sign = sign_a;
        end else begin
            if (add_mant_shifted_a >= add_mant_shifted_b) begin
                add_mant_res = add_mant_shifted_a - add_mant_shifted_b;
                add_sign = sign_a;
            end else begin
                add_mant_res = add_mant_shifted_b - add_mant_shifted_a;
                add_sign = sign_b;
            end
        end

        // 3. Normalization (Priority Encoder)
        norm_mant = 24'd0;
        norm_exp = add_exp;
        
        if (add_mant_res[24]) begin // Overflow from addition
            norm_mant = add_mant_res[24:1];
            norm_exp = add_exp + 1;
        end else if (add_mant_res[23]) begin // Already normalized
            norm_mant = add_mant_res[23:0];
        end else begin // Underflow from subtraction, find leading 1
            norm_mant = add_mant_res[23:0];
            for (i = 0; i < 24; i = i + 1) begin
                if (!norm_mant[23] && norm_mant != 0) begin
                    norm_mant = norm_mant << 1;
                    norm_exp = norm_exp - 1;
                end
            end
            if (add_mant_res == 0) norm_exp = 0;
        end
    end

    // FP MULTIPLIER DATAPATH
    wire [47:0] mul_mant_full = mant_a * mant_b;
    wire [8:0]  mul_exp_raw = exp_a + exp_b - bias;
    reg  [23:0] mul_norm_mant;
    reg  [7:0]  mul_norm_exp;
    wire        mul_sign = sign_a ^ sign_b;

    always @(*) begin
        if (mul_mant_full[47]) begin // FP32 overflow
            mul_norm_mant = mul_mant_full[47:24];
            mul_norm_exp = mul_exp_raw + 1;
        end else if (mul_mant_full[46]) begin
            mul_norm_mant = mul_mant_full[46:23];
            mul_norm_exp = mul_exp_raw;
        end else if (mul_mant_full[21] && !sew) begin // FP16 check
            mul_norm_mant = {13'b0, mul_mant_full[21:11]};
            mul_norm_exp = mul_exp_raw + 1;
        end else if (mul_mant_full[20] && !sew) begin
            mul_norm_mant = {13'b0, mul_mant_full[20:10]};
            mul_norm_exp = mul_exp_raw;
        end else begin
            mul_norm_mant = 24'd0;
            mul_norm_exp = 8'd0;
        end
        if (exp_a == 0 || exp_b == 0) begin // Handle multiplication by 0
            mul_norm_exp = 0;
            mul_norm_mant = 0;
        end
    end

    // Muxing FP Results
    always @(*) begin
        fp_res = 32'd0;
        if (opcode == OP_FADD || opcode == OP_FSUB) begin
            if (sew) fp_res = {add_sign, norm_exp[7:0], norm_mant[22:0]}; // FP32
            else     fp_res = {16'b0, add_sign, norm_exp[4:0], norm_mant[9:0]}; // FP16
        end else if (opcode == OP_FMUL) begin
            if (sew) fp_res = {mul_sign, mul_norm_exp[7:0], mul_norm_mant[22:0]}; // FP32
            else     fp_res = {16'b0, mul_sign, mul_norm_exp[4:0], mul_norm_mant[9:0]}; // FP16
        end
    end

    // -------------------------------------------------------------------------
    // WRITEBACK & PREDICATION
    // -------------------------------------------------------------------------
    always @(*) begin
        if (opcode >= OP_FADD) final_res = fp_res;
        else final_res = int_res;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_vd <= 32'd0;
            valid_out <= 1'b0;
        end else begin
            // Apply vector mask: if mask=0, keep old data
            out_vd <= mask ? final_res : old_vd;
            valid_out <= 1'b1;
        end
    end

endmodule
