module alu_eq (
  input  logic [63:0] a_i,
  input  logic [63:0] b_i,
  input  logic [6:0]  sig_i,
  output logic        eq_o,
  output logic        error_o
);
  always_comb begin
    eq_o = 1'b0;
    error_o = 1'b0;

    case (sig_i)
      7'd16: begin // EQ.F16
        error_o = (&a_i[14:10]) || (&b_i[14:10]);
        if (!error_o) begin
          eq_o = (a_i[15:0] == b_i[15:0]) ||
               ((a_i[14:0] == 15'b0) && (b_i[14:0] == 15'b0));
        end
      end

      7'd17: begin // EQ.F32
        error_o = (&a_i[30:23]) || (&b_i[30:23]);
        if (!error_o) begin
          eq_o = (a_i[31:0] == b_i[31:0]) ||
               ((a_i[30:0] == 31'b0) && (b_i[30:0] == 31'b0));
        end
      end

      7'd18, 7'd19: eq_o = (a_i[31:0] == b_i[31:0]); // I32/U32
      7'd20, 7'd21: eq_o = (a_i == b_i);             // I64/U64

      default: error_o = 1'b1;
    endcase
  end
endmodule
