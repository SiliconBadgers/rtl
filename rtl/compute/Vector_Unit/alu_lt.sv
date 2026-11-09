module alu_lt (
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic [6:0]  sig_i,
  output logic        lt_o,
  output logic        error_o
);
  always_comb begin
    lt_o = 1'b0;
    error_o = 1'b0;

    case (sig_i)
      7'd24: begin // LT.F16
        error_o = (&a_i[14:10]) || (&b_i[14:10]);
        if (!error_o) begin
          // Both zero signs compare equal.
          if ((a_i[14:0] == 15'b0) && (b_i[14:0] == 15'b0)) begin
            lt_o = 1'b0;
          end else if (a_i[15] != b_i[15]) begin
            lt_o = a_i[15];
          end else if (a_i[15]) begin
            lt_o = (a_i[14:0] > b_i[14:0]); // Both negative.
          end else begin
            lt_o = (a_i[14:0] < b_i[14:0]); // Both positive.
          end
        end
      end

      7'd25: begin // LT.F32
        error_o = (&a_i[30:23]) || (&b_i[30:23]);
        if (!error_o) begin
          if ((a_i[30:0] == 31'b0) && (b_i[30:0] == 31'b0)) begin
            lt_o = 1'b0;
          end else if (a_i[31] != b_i[31]) begin
            lt_o = a_i[31];
          end else if (a_i[31]) begin
            lt_o = (a_i[30:0] > b_i[30:0]);
          end else begin
            lt_o = (a_i[30:0] < b_i[30:0]);
          end
        end
      end

      7'd26: lt_o = ($signed(a_i[31:0]) < $signed(b_i[31:0])); // I32
      7'd27: lt_o = (a_i[31:0] < b_i[31:0]);                  // U32
      7'd28: lt_o = ($signed(a_i) < $signed(b_i));             // I64
      7'd29: lt_o = (a_i < b_i);                              // U64

      default: error_o = 1'b1;
    endcase
  end
endmodule
