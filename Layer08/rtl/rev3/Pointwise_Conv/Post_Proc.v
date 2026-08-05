`timescale 1ns / 1ps
//==========================================================
// Post_Proc — 후처리 유닛 (노션 스펙 §5.4 융합, §4.5 Q 포맷)
//
//   완성 누산값 스트림(8레인)에 원소별로:
//     +bias(32b, 누산기 스케일) → ReLU6(누산기 스케일에서 클램프)
//     → ≫REQ_SHIFT 재양자화 (round-half-up: 2^(s-1) 가산 후 산술 시프트)
//     → 포화 → 16b 출력
//
//   ⚠ 연산 순서·반올림 규칙은 고정소수점 C 모델(fixp_layer08.c)과
//     반드시 동일 — 다르면 ±1 LSB 무작위 오차 (§4.5 부가 결정)
//
//   PW1(expand): RELU_EN=1, ACC_FRAC=28, REQ_SHIFT=15 → UQ3.13 (0~49152)
//   PW2(proj)  : RELU_EN=0, ACC_FRAC=27, REQ_SHIFT=15 → Q3.12 signed 포화
//                (+residual 정수 덧셈은 TODO — PW2 단계에서 추가)
//==========================================================
module Post_Proc #(
    parameter DATA_W    = 16,
    parameter ACC_W     = 32,
    parameter LANES     = 8,
    parameter REQ_SHIFT = 15,   // 재양자화 시프트량
    parameter ACC_FRAC  = 28,   // 누산기 소수부 (ReLU6 상한 = 6 << ACC_FRAC)
    parameter RELU_EN   = 1    // 1: ReLU6, 0: linear (proj 단계)
)(
    input                           clk,
    input                           rst,

    input   [LANES-1:0]             in_valid,
    input   [LANES*ACC_W-1:0]       in_acc,     // 완성 누산값 (bias 미포함)
    input   [LANES*16-1:0]          in_pos,

    input   [LANES*ACC_W-1:0]       bias_in,    // 레인별 bias (현재 필터 타일)

    output reg [LANES-1:0]          out_valid,
    output reg [LANES*DATA_W-1:0]   out_data,   // UQ3.13 (또는 Q3.12)
    output reg [LANES*16-1:0]       out_pos
);

    localparam signed [ACC_W-1:0] RELU6_MAX = 32'sd6 <<< ACC_FRAC;   // 6.0의 누산기 스케일 코드

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : LANE

            // ① bias 가산 (32b — 실측 최대 29비트라 오버플로 없음, C 모델로 확인)
            wire signed [ACC_W-1:0] biased  = $signed(in_acc[gl*ACC_W +: ACC_W])
                                            + $signed(bias_in[gl*ACC_W +: ACC_W]);

            // ② ReLU6 — 누산기 스케일에서 클램프 (C 모델과 동일 순서)
            wire signed [ACC_W-1:0] clamped = (RELU_EN && (biased < 0))         ? {ACC_W{1'b0}} :
                                              (RELU_EN && (biased > RELU6_MAX)) ? RELU6_MAX     :
                                                                                  biased;

            // ③ round-half-up 재양자화: 2^(s-1) 가산 후 산술 시프트
            wire signed [ACC_W-1:0] shifted = (clamped + (32'sd1 <<< (REQ_SHIFT-1))) >>> REQ_SHIFT;

            // ④ 포화 — RELU_EN=1이면 결과 ≤ 6·2^13 = 49152라 16b에 그대로,
            //           RELU_EN=0(linear)이면 signed 16b 포화
            wire [DATA_W-1:0] satval = (RELU_EN)            ? shifted[DATA_W-1:0] :
                                       (shifted >  32767)   ? 16'h7FFF :
                                       (shifted < -32768)   ? 16'h8000 :
                                                              shifted[DATA_W-1:0];

            always @(posedge clk or posedge rst) begin
                if (rst) begin
                    out_valid[gl]              <= 1'b0;
                    out_data[gl*DATA_W +: DATA_W] <= {DATA_W{1'b0}};
                    out_pos[gl*16 +: 16]       <= 16'd0;
                end
                else begin
                    out_valid[gl]              <= in_valid[gl];
                    out_data[gl*DATA_W +: DATA_W] <= satval;
                    out_pos[gl*16 +: 16]       <= in_pos[gl*16 +: 16];
                end
            end
        end
    endgenerate

endmodule
