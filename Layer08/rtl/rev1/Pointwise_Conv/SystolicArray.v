`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 02:37:08
// Design Name: 
// Module Name: SystolicArray
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
// SystolicArray — 8x8 Weight-Stationary PE 배열 (노션 스펙 §3, §6.1 pe_array)
//
// 배선만 있는 껍데기 — 카운터/판단 로직 금지 (제어는 ctrl_fsm 담당)
//
//   x    : 왼쪽 → 오른쪽  (skew_regs가 행 i를 i클럭 지연시켜 공급하는 전제)
//   w    : 위   → 아래    (LOAD 구간 shift-in 체인, 역순 공급 전제)
//   psum : 위   → 아래    (행 0은 0에서 시작, 맨 아래 행에서 열별 완성)
//
// 출력은 맨 아래 행의 psum만 (WS는 결과가 열 아래로 흘러나오므로
// OS처럼 PE 64개 전체를 밖으로 뺄 필요가 없음).
// 열 j의 결과는 j클럭씩 늦게 나옴 → de-skew는 누산 버퍼 쓰기 주소로 흡수 (§4.3)
//==========================================================
module SystolicArray #(
    parameter DATA_W = 16,   // 활성/가중치 폭 (Q3.12, UQ3.13, 2^-n 스케일)
    parameter ACC_W  = 32,   // 부분합 폭 — 32b signed 통일 (스펙 §4.4)
    parameter PE_ROW = 8,    // 입력 채널 타일 (누산 차원)
    parameter PE_COL = 8     // 출력 필터 타일 (병렬 차원)
)(
    input                           clk,
    input                           rst,

    input                           en,         // CALC/DRAIN 구간 enable
    input                           load_mode,  // 1: 가중치 shift-in

    input  [PE_ROW*DATA_W-1:0]      x_in,       // 왼쪽 테두리: 행당 16b (skew 정렬된 입력)
    input  [PE_COL*DATA_W-1:0]      w_in,       // 위쪽 테두리: 열당 16b (LOAD 시 가중치)

    output [PE_COL*ACC_W-1:0]       psum_out    // 아래쪽 테두리: 열당 32b 완성 부분합
);

    // 각 PE 사이를 연결할 내부 Wire 배열 선언
    wire [DATA_W-1:0] x_wire    [PE_ROW-1:0][PE_COL:0]; // Col 0은 외부 입력, 마지막 Col은 버려짐
    wire [DATA_W-1:0] w_wire    [PE_ROW:0][PE_COL-1:0]; // Row 0은 외부 입력, 마지막 Row는 버려짐
    wire [ACC_W-1:0]  psum_wire [PE_ROW:0][PE_COL-1:0]; // Row 0은 0 고정, 마지막 Row가 출력

    genvar i, j;

    // 외부 입출력을 가장자리(Edge) Wire에 연결
    generate
        for (i = 0; i < PE_ROW; i = i + 1) begin : EDGE_ROW
            assign x_wire[i][0] = x_in[(i+1)*DATA_W-1 : i*DATA_W];           // 왼쪽 테두리
        end
        for (j = 0; j < PE_COL; j = j + 1) begin : EDGE_COL
            assign w_wire[0][j]    = w_in[(j+1)*DATA_W-1 : j*DATA_W];        // 위쪽 테두리
            assign psum_wire[0][j] = {ACC_W{1'b0}};                          // 행 0의 부분합은 0에서 시작
            assign psum_out[(j+1)*ACC_W-1 : j*ACC_W] = psum_wire[PE_ROW][j]; // 아래쪽 테두리
        end
    endgenerate

    // ROW x COL PE
    generate
        for (i = 0; i < PE_ROW; i = i + 1) begin : ROWS
            for (j = 0; j < PE_COL; j = j + 1) begin : COLS
                ProcessingElement #(
                    .DATA_W         (DATA_W),
                    .ACC_W          (ACC_W)
                ) pe_inst (
                    .clk            (clk),
                    .rst            (rst),

                    .en             (en),
                    .load_mode      (load_mode),

                    .x_in           (x_wire[i][j]),        // 내 왼쪽 Wire에서 받아서
                    .w_in           (w_wire[i][j]),        // 내 위쪽 Wire에서 받아서
                    .psum_in        (psum_wire[i][j]),     // 위쪽 부분합을 받아서

                    .x_out          (x_wire[i][j+1]),      // 내 오른쪽 Wire로 던진다!
                    .w_out          (w_wire[i+1][j]),      // 내 아래쪽 Wire로 던진다!
                    .psum_out       (psum_wire[i+1][j])    // 누산 결과도 아래쪽으로!
                );
            end
        end
    endgenerate
    //==========================================================

endmodule
