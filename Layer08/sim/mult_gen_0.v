`timescale 1ns / 1ps
// 시뮬레이션 전용 스텁 — Vivado Multiplier(mult_gen) 12.0 대체 (Vivado 프로젝트에 추가 금지!)
//   16x16 signed → 32b, Pipeline Stages = 4 (곱셈 결과가 4클럭 뒤에 나옴)
//   CE/SCLR 미사용 구성 — 항상 클럭마다 파이프가 전진한다는 점 주의
module mult_gen_0 (
    input               CLK,
    input      [15:0]   A,
    input      [15:0]   B,
    output     [31:0]   P
);
    reg signed [31:0] p1, p2, p3, p4;

    always @(posedge CLK) begin
        p1 <= $signed(A) * $signed(B);
        p2 <= p1;
        p3 <= p2;
        p4 <= p3;
    end

    assign P = p4;
endmodule
