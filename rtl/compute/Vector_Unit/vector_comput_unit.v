`timescale 1ns / 1ps

module vector_compute_unit (
    input  wire         clk,
    input  wire         rst_n,
    
    // Decoder Control Signals
    input  wire [3:0]   opcode,     // ALU/FPU operation selection
    input  wire         sew,        // 0 = 16-bit elements, 1 = 32-bit elements
    
    // Mask Register (v0)
    input  wire [3:0]   v0_mask,    // 1 bit per lane: 1 = execute, 0 = masked
    
    // Vector Source and Destination Registers (VLEN = 128 bits)
    input  wire [127:0] vs1,        // Vector Source 1
    input  wire [127:0] vs2,        // Vector Source 2
    input  wire [127:0] old_vd,     // Original destination data (for masking)
    
    output wire [127:0] vd_out,     // Vector Destination Write-back
    output wire         valid_out   // High when computation is complete
);

    // -------------------------------------------------------------------------
    // SLICER NETWORK: Operand Data Routing
    // -------------------------------------------------------------------------
    // The slicer dynamically maps the 128-bit input buses to 32-bit lane inputs
    // based on the requested SEW.
    wire [31:0] lane_in_a [3:0];
    wire [31:0] lane_in_b [3:0];
    wire [31:0] lane_old_vd [3:0];
    wire [31:0] lane_out [3:0];
    wire [3:0]  lane_valid;

    // Lane 0 Slicing
    assign lane_in_a[0]   = sew ? vs1[31:0]   : {16'b0, vs1[15:0]};
    assign lane_in_b[0]   = sew ? vs2[31:0]   : {16'b0, vs2[15:0]};
    assign lane_old_vd[0] = sew ? old_vd[31:0]: {16'b0, old_vd[15:0]};

    // Lane 1 Slicing
    assign lane_in_a[1]   = sew ? vs1[63:32]  : {16'b0, vs1[31:16]};
    assign lane_in_b[1]   = sew ? vs2[63:32]  : {16'b0, vs2[31:16]};
    assign lane_old_vd[1] = sew ? old_vd[63:32]: {16'b0, old_vd[31:16]};

    // Lane 2 Slicing
    assign lane_in_a[2]   = sew ? vs1[95:64]  : {16'b0, vs1[47:32]};
    assign lane_in_b[2]   = sew ? vs2[95:64]  : {16'b0, vs2[47:32]};
    assign lane_old_vd[2] = sew ? old_vd[95:64]: {16'b0, old_vd[47:32]};

    // Lane 3 Slicing
    assign lane_in_a[3]   = sew ? vs1[127:96] : {16'b0, vs1[63:48]};
    assign lane_in_b[3]   = sew ? vs2[127:96] : {16'b0, vs2[63:48]};
    assign lane_old_vd[3] = sew ? old_vd[127:96]: {16'b0, old_vd[63:48]};

    // -------------------------------------------------------------------------
    // PARALLEL EXECUTION LANES
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lanes
            vector_lane_compute u_lane (
                .clk(clk),
                .rst_n(rst_n),
                .opcode(opcode),
                .sew(sew),
                .mask(v0_mask[i]),
                .in_a(lane_in_a[i]),
                .in_b(lane_in_b[i]),
                .old_vd(lane_old_vd[i]),
                .out_vd(lane_out[i]),
                .valid_out(lane_valid[i])
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // WRITE-BACK AGGREGATOR
    // -------------------------------------------------------------------------
    // Reassemble the lane outputs back into the 128-bit destination bus.
    // If SEW=0 (16-bit), the upper 16 bits of each lane output are ignored 
    // and packed tightly.
    assign vd_out = sew ? 
        {lane_out[3], lane_out[2], lane_out[1], lane_out[0]} : 
        {
            16'b0, 16'b0, 16'b0, 16'b0, // Upper 64 bits untouched/zeroed in this basic 1-cycle view
            lane_out[3][15:0], lane_out[2][15:0], lane_out[1][15:0], lane_out[0][15:0]
        };

    // Global valid signal goes high when all enabled lanes complete
    assign valid_out = &lane_valid;

endmodule
