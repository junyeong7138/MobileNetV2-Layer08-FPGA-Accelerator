`timescale 1ns / 1ps
// 시뮬레이션 전용 스텁 — Vivado Multiplier(mult_gen) 12.0 대체 (Vivado 프로젝트에 추가 금지!)
//   A unsigned(16) × B signed(16) → 32b, Pipeline Stages = 4 (mult_gen_0과 동일 지연 필수)
//   DW용: A = UQ3.13 활성(항상 ≥0, 최대 49152 > 32767이라 unsigned 해석이 핵심)
//   CE/SCLR 미사용 구성 — 항상 클럭마다 파이프가 전진한다는 점 주의
module mult_gen_1 (
    input               CLK,
    input      [15:0]   A,
    input      [15:0]   B,
    output     [31:0]   P
);
    reg signed [31:0] p1, p2, p3, p4;

    always @(posedge CLK) begin
        p1 <= $signed({1'b0, A}) * $signed(B);      // A를 0 확장 = unsigned 해석
        p2 <= p1;
        p3 <= p2;
        p4 <= p3;
    end

    assign P = p4;
endmodule
