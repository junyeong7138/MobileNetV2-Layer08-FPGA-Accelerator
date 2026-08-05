`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 14:15:43
// Design Name: 
// Module Name: Skew_Regs
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
// Skew_Regs — 입력 계단 지연 (노션 스펙 §4.3, §6.1)
//
// 메모리에서 같은 주소로 읽은 "같은 위치의 8채널"을
// 행 i마다 i클럭씩 지연시켜 SA 왼쪽 테두리의 계단(skew)을 만든다.
//   행 0 : 지연 0 (통과)
//   행 i : i단 FF 체인
//
// 로직 없는 순수 FF 다발 → 구조가 곧 문서 (stage_E_M 스타일 논의 참조).
// en 게이트 없음(자유 진행) — 곱셈기 파이프와 같은 원리로, 스트림이 멈춘
// 구간의 잔여물은 Ctrl_FSM valid 윈도우가 걸러낸다.
//==========================================================
module Skew_Regs #(
    parameter DATA_W = 16,
    parameter PE_ROW = 8
)(
    input                           clk,
    input                           rst,

    input   [PE_ROW*DATA_W-1:0]     din,    // 메모리 정렬 데이터 (행당 16b, 동일 위치)
    output  [PE_ROW*DATA_W-1:0]     dout    // 계단 정렬 (행 i = i클럭 지연)
);

    genvar gi;
    generate
        for (gi = 0; gi < PE_ROW; gi = gi + 1) begin : ROW_DELAY
            if (gi == 0) begin : PASS
                // 행 0은 지연 없이 통과
                assign dout[DATA_W-1:0] = din[DATA_W-1:0];
            end
            else begin : CHAIN
                // 행 gi: gi단 시프트 체인 (LSB쪽으로 새 값이 들어와 MSB쪽으로 나감)
                reg [gi*DATA_W-1:0] chain;

                always @(posedge clk or posedge rst) begin
                    if (rst) chain <= {gi*DATA_W{1'b0}};
                    else     chain <= {chain, din[gi*DATA_W +: DATA_W]};    // 좌시프트 (자동 절단)
                end

                assign dout[gi*DATA_W +: DATA_W] = chain[gi*DATA_W-1 -: DATA_W];
            end
        end
    endgenerate

endmodule
