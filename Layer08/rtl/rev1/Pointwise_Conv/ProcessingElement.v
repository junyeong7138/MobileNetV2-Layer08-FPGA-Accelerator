`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 02:39:44
// Design Name: 
// Module Name: ProcessingElement
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

//==========================================================
// ProcessingElement — Weight-Stationary (노션 스펙 §3.2)
//
// LOAD (load_mode=1) : w_in → w_reg → w_out 로 아래 방향 shift-in 체인.
//                      8클럭이면 8행 전체 로드 완료 (가중치는 역순 공급).
// CALC (en=1)        : w_reg 고정.
//                      x    : 왼쪽 → 오른쪽 (입력 재사용)
//                      psum : 위   → 아래   (부분합 누산)
//                      psum_out <= psum_in + mul(4클럭 전 x_in × w_reg)
//
// 1차 구현에서는 load_mode와 en을 FSM이 상호 배타로 구동한다
// (LOAD 중 en=0). 파면(wavefront) 로딩은 2차 개선 항목.
//==========================================================
module ProcessingElement #(
    parameter DATA_W = 16,   // 활성/가중치 폭 (Q3.12, UQ3.13, 2^-n 스케일)
    parameter ACC_W  = 32    // 부분합 폭 — 32b signed 통일 (스펙 §4.4)
)(
    input                       clk,
    input                       rst,        // active-high

    input                       en,         // CALC/DRAIN 구간 enable
    input                       load_mode,  // 1: 가중치 shift-in

    input      [DATA_W-1:0]     x_in,       // 왼쪽 PE(또는 skew_regs)에서 오는 입력
    input      [DATA_W-1:0]     w_in,       // 위쪽 PE(또는 가중치 버퍼)에서 오는 가중치
    input      [ACC_W-1:0]      psum_in,    // 위쪽 PE에서 내려오는 부분합 (행 0은 0 고정)

    output reg [DATA_W-1:0]     x_out,      // 오른쪽 PE로 전달
    output     [DATA_W-1:0]     w_out,      // 아래쪽 PE의 w_in으로 (shift 체인)
    output reg [ACC_W-1:0]      psum_out    // 아래쪽 PE의 psum_in으로
);

    //=============================
    // 가중치 레지스터 — LOAD 구간에만 한 칸씩 이동, CALC 중에는 고정
    reg [DATA_W-1:0] w_reg;

    always @(posedge clk or posedge rst) begin
        if (rst)            w_reg <= {DATA_W{1'b0}};
        else if (load_mode) w_reg <= w_in;
    end

    assign w_out = w_reg;   // 아래 PE는 다음 클럭에 내 현재 값을 받는다

    //=============================
    // MAC : 곱셈은 Vivado Multiplier IP (mult_gen_0, 16x16 signed → 32b)
    //   ⚠ Pipeline Stages = 4 → 곱 결과가 4클럭 뒤에 나옴 (MUL_LAT=4)
    //     행마다 지연이 동일해서 서로 상쇄 → skew 구조는 그대로,
    //     배열 출력 타이밍만 전체 +4클럭 (Ctrl_FSM valid/DRAIN이 보정)
    //   ⚠ CE 미사용 구성 — en=0이어도 곱셈 파이프는 계속 돈다.
    //     LOAD 잔여물(stale 곱)은 valid 윈도우 밖이라 무해하지만,
    //     en이 CALC 중간에 꺼지는 설계로 바꾸면 IP에 CE를 켜고 en 연결 필수.
    //   시뮬은 sim/mult_gen_0.v 스텁 사용 (Vivado 프로젝트에는 추가 금지)
    wire [ACC_W-1:0] mul;

    mult_gen_0 u_mult (
        .CLK    (clk  ),
        .A      (x_in ),
        .B      (w_reg),
        .P      (mul  )
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x_out    <= {DATA_W{1'b0}};
            psum_out <= {ACC_W{1'b0}};
        end else if (en) begin
            x_out    <= x_in;                                // 1. 받은 입력을 오른쪽으로 패스
            psum_out <= $signed(psum_in) + $signed(mul);     // 2. 4클럭 전 입력의 곱을 더해 아래로 패스
        end
    end
    //=============================

endmodule
