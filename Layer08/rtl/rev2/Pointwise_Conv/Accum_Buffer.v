`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 14:22:02
// Design Name: 
// Module Name: Accum_Buffer
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
// Accum_Buffer — 부분합 누산 버퍼 (노션 스펙 §4.4)
//
//   8뱅크 × 196 × 32b (BRAM 추론, 뱅크당 BRAM18 1개)
//   행 타일링의 산물: 채널 타일 8회가 다 돌아야 한 위치가 완성되므로
//   미완성 부분합을 타일 사이에 보관한다.
//
//   - de-skew: 열 j의 쓰기 위치 = calc_cyc_cnt - ADDR_OFFSET - j
//     (별도 FF 역계단 없이 주소로 흡수 — 스펙 §4.3)
//   - RMW 2단 파이프: t에 read 발행+psum 캡처 → t+1에 add+write
//     Hazard 없음 증명: 주소가 매 사이클 단조 증가, 같은 주소 재방문은
//     다음 채널 타일(≥196+α 사이클 뒤) → read/write 충돌 원천 배제
//   - 초기화: first_ch_tile bypass (acc_new = first ? psum : old + psum)
//     → 사전 0 클리어 사이클 없음, BRAM은 리셋 불가하므로 이 방식이 정석
//   - 마지막 채널 타일의 완성값은 저장과 동시에 out_* 스트림으로 배출
//     (융합: 완성값을 다시 읽지 않고 흘러가는 채로 post_proc에 전달 — §5.4)
//==========================================================
module Accum_Buffer #(
    parameter ACC_W       = 32,
    parameter PE_COL      = 8,
    parameter DEPTH       = 196,    // LAYER_HW
    parameter ADDR_OFFSET = 13      // PE_ROW + MUL_LAT + MEM_LAT (valid 윈도우 시작)
)(
    input                           clk,
    input                           rst,

    input   [15:0]                  calc_cyc_cnt,
    input   [PE_COL-1:0]            valid,          // 열별 psum 유효 (Ctrl_FSM)
    input                           first_ch_tile,  // bypass 게이트
    input                           last_ch_tile,   // 완성값 배출 게이트

    input   [PE_COL*ACC_W-1:0]      psum_in,        // SA 바닥 psum

    output  [PE_COL-1:0]            out_valid,      // 완성값 스트림 (마지막 채널 타일만)
    output  [PE_COL*ACC_W-1:0]      out_acc,
    output  [PE_COL*16-1:0]         out_pos         // 완성값의 위치 인덱스
);

    genvar gj;
    generate
        for (gj = 0; gj < PE_COL; gj = gj + 1) begin : BANK

            // 뱅크별 독립 메모리 — 열마다 쓰기 주소가 j클럭씩 어긋나므로 합치면 안 됨 (§5.2)
            (* ram_style = "block" *) reg [ACC_W-1:0] mem [0:DEPTH-1];

            wire [15:0] wr_pos = calc_cyc_cnt - ADDR_OFFSET - gj;   // de-skew 주소

            // ---- 1단: read 발행 + 입력 캡처 ----
            reg  [ACC_W-1:0]    rd_data, psum_d;
            reg  [15:0]         pos_d;
            reg                 valid_d, first_d, last_d;

            always @(posedge clk) begin
                rd_data <= mem[wr_pos[7:0]];                        // 읽기 지연 1
            end

            always @(posedge clk or posedge rst) begin
                if (rst) begin
                    psum_d  <= {ACC_W{1'b0}};
                    pos_d   <= 16'd0;
                    valid_d <= 1'b0;
                    first_d <= 1'b0;
                    last_d  <= 1'b0;
                end
                else begin
                    psum_d  <= psum_in[gj*ACC_W +: ACC_W];
                    pos_d   <= wr_pos;
                    valid_d <= valid[gj];
                    first_d <= first_ch_tile;
                    last_d  <= last_ch_tile;
                end
            end

            // ---- 2단: add + write (+완성값 배출) ----
            wire [ACC_W-1:0] acc_new = first_d ? psum_d : (rd_data + psum_d);

            always @(posedge clk) begin
                if (valid_d) mem[pos_d[7:0]] <= acc_new;
            end

            assign out_valid[gj]            = valid_d && last_d;
            assign out_acc[gj*ACC_W +: ACC_W] = acc_new;
            assign out_pos[gj*16 +: 16]     = pos_d;
        end
    endgenerate

endmodule
