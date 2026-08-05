`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 02:35:36
// Design Name: 
// Module Name: Ctrl_FSM
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
// Ctrl_FSM — pw_engine 로컬 제어 (노션 스펙 §6.3)
//
// IDLE →(start)→ LOAD(PE_ROW클럭, 가중치 shift-in)
//              → CALC(LAYER_HW클럭, 입력 스트리밍)
//              → DRAIN(잔여 psum 배출, PE_ROW+PE_COL+2클럭)
//              → 분기: ch_tile_cnt++ → LOAD (채널 타일 교체)
//                      filter_tile_cnt++ → LOAD (필터 타일 교체, ch_tile_cnt=0)
//                      둘 다 끝 → DONE(done 1클럭 펄스) → IDLE
//
// 설계 규칙
//  - 상태 인코딩(localparam)은 이 모듈 밖으로 내보내지 않는다.
//    바깥에는 제어 "신호"만 출력 (load_mode/en/valid/done/카운터).
//  - 카운터는 c_state 기준으로 센다 (상태 구간과 1:1 정렬, 상태 이탈 시 0).
//  - 출력 신호는 n_state 기준 레지스터
//    (글리치 없음 + c_state와 동일 타이밍, PE 64개 팬아웃 대비).
//==========================================================
module Ctrl_FSM #(
    parameter PE_ROW   = 8,     // SA 행 수 = LOAD 클럭 수
    parameter PE_COL   = 8,     // SA 열 수
    parameter LAYER_HW = 196,   // 타일당 위치 수 (14x14)
    parameter N_CTILE  = 8,     // 입력 채널 타일 수 (예: 64/8)
    parameter N_FTILE  = 48,    // 출력 필터 타일 수 (예: 384/8)
    parameter MUL_LAT  = 4,     // PE 곱셈기 IP 파이프라인 지연 (mult_gen_0 Pipeline Stages)
    parameter MEM_LAT  = 1      // 버퍼 BRAM 읽기 지연 (Primitives Output Register OFF = 1클럭)
)(
    // ------- input -------
    clk,
    rst,

    start,

    // ------- output -------
    load_mode,      // LOAD 구간 1 — SA shift-in
    en,             // CALC+DRAIN 구간 1 — SA 파이프라인 진행
    valid,          // 열별 psum 유효 윈도우 (누산 버퍼 쓰기 게이트)
    done,           // 전체 타일 완료 1클럭 펄스

    load_cnt,       // LOAD 진행 카운터  (가중치 버퍼 읽기 주소용)
    calc_cyc_cnt,        // CALC+DRAIN 카운터 (입력 읽기 주소·valid 기준)
    ch_tile_cnt,         // 현재 채널 타일
    filter_tile_cnt,         // 현재 필터 타일
    first_ch_tile,    // ch_tile_cnt==0        → 누산 버퍼 bypass (acc_new = psum)
    last_ch_tile      // ch_tile_cnt==끝       → 완성값 → post_proc 전달 구간
);
    // ==========================================================
    // ------- input -------
    input                   clk;
    input                   rst;

    input                   start;

    // ------- output -------
    output                  load_mode;
    output                  en;
    output  [PE_COL-1:0]    valid;
    output                  done;

    output  [15:0]          load_cnt;
    output  [15:0]          calc_cyc_cnt;
    output  [15:0]          ch_tile_cnt;
    output  [15:0]          filter_tile_cnt;
    output                  first_ch_tile;
    output                  last_ch_tile;

    // ==========================================================
    localparam IDLE     = 3'b000;
    localparam LOAD     = 3'b001;
    localparam CALC     = 3'b010;
    localparam DRAIN    = 3'b011;
    localparam DONE     = 3'b100;

    // 마지막 열 출력 = (LAYER_HW-1) + PE_ROW + (PE_COL-1) + MUL_LAT + MEM_LAT 사이클.
    // 거기에 RMW(read→add→write) 여유 +3
    // → DRAIN 길이 = PE_ROW+PE_COL+MUL_LAT+MEM_LAT+2
    //   (곱셈기 4클럭 파이프라인 + 메모리 읽기 1클럭 배출 포함)
    localparam CYC_END  = LAYER_HW + PE_ROW + PE_COL + MUL_LAT + MEM_LAT + 1;

    reg     [ 2:0]      c_state, n_state;

    always @(posedge clk or posedge rst) begin
        if(rst) c_state <= IDLE;
        else    c_state <= n_state;
    end

    // ==========================================================
    // next-state 조합 로직

    always @(*) begin
        n_state = c_state;

        case(c_state)
            IDLE: begin
                n_state = (start == 1'b1)?  LOAD :
                                            IDLE;
            end

            LOAD: begin
                n_state = (load_cnt == PE_ROW-1)?   CALC :
                                                    LOAD;
            end

            CALC: begin
                n_state = (calc_cyc_cnt == LAYER_HW-1)?  DRAIN :
                                                    CALC;
            end

            DRAIN: begin
                if (calc_cyc_cnt == CYC_END) begin
                    if      (ch_tile_cnt != N_CTILE-1)   n_state = LOAD;  // 다음 채널 타일
                    else if (filter_tile_cnt != N_FTILE-1)   n_state = LOAD;  // 다음 필터 타일
                    else                            n_state = DONE;  // 전부 끝
                end
            end

            DONE: begin
                n_state = IDLE;     // 1클럭 체류 → done 펄스 폭 = 1클럭
            end

            default: begin
                n_state = IDLE;
            end
        endcase
    end

    // ==========================================================
    // 카운터 — c_state 기준 (해당 상태에서만 증가, 벗어나면 0)

    reg     [15:0]      load_cnt, calc_cyc_cnt;

    always @(posedge clk or posedge rst) begin
        if(rst)                         load_cnt <= 16'd0;
        else if (c_state == LOAD)       load_cnt <= load_cnt + 16'd1;
        else                            load_cnt <= 16'd0;
    end

    // CALC에서 0부터 세기 시작해 DRAIN까지 이어서 센다 (valid 윈도우의 기준 축)
    always @(posedge clk or posedge rst) begin
        if(rst)                                             calc_cyc_cnt <= 16'd0;
        else if (c_state == CALC || c_state == DRAIN)       calc_cyc_cnt <= calc_cyc_cnt + 16'd1;
        else                                                calc_cyc_cnt <= 16'd0;
    end

    // 타일 카운터 — DRAIN 종료 시점에 갱신
    reg     [15:0]      ch_tile_cnt, filter_tile_cnt;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            ch_tile_cnt <= 16'd0;
            filter_tile_cnt <= 16'd0;
        end
        else if (c_state == IDLE) begin
            ch_tile_cnt <= 16'd0;
            filter_tile_cnt <= 16'd0;
        end
        else if (c_state == DRAIN && calc_cyc_cnt == CYC_END) begin
            if (ch_tile_cnt != N_CTILE-1) begin
                ch_tile_cnt <= ch_tile_cnt + 16'd1;
            end
            else begin
                ch_tile_cnt <= 16'd0;
                filter_tile_cnt <= filter_tile_cnt + 16'd1;   // 마지막 타일이면 어차피 DONE→IDLE에서 클리어
            end
        end
    end

    assign first_ch_tile = (ch_tile_cnt == 16'd0);
    assign last_ch_tile  = (ch_tile_cnt == N_CTILE-1);

    // ==========================================================
    // 출력 신호 — n_state 기준 레지스터 (모든 경로에서 값 확정 → 눌러붙음 없음)

    reg                 load_mode, en, done;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            load_mode   <= 1'b0;
            en          <= 1'b0;
            done        <= 1'b0;
        end
        else begin
            load_mode   <= (n_state == LOAD);
            en          <= (n_state == CALC) || (n_state == DRAIN);   // DRAIN에도 1! (psum 배출)
            done        <= (n_state == DONE);
        end
    end

    // ==========================================================
    // 열별 valid 윈도우 (스펙 §4.3 + 곱셈기/메모리 지연 보정)
    //   열 j의 psum_out은
    //   calc_cyc_cnt ∈ [PE_ROW+MUL_LAT+MEM_LAT+j, PE_ROW+MUL_LAT+MEM_LAT+j+LAYER_HW) 에서 유효.
    //   (MEM_LAT: 읽기 주소 발행 → 데이터 도착 1클럭. pw_engine의 load_mode/en
    //    1클럭 지연판과 세트로 동작 — 통합 TB tb_Layer08에서 실데이터 검증)
    //   지연 오프셋 덕에 LOAD 잔여물(stale 곱)도 자연히 윈도우 밖으로 걸러짐.

    genvar gj;
    generate
        for (gj = 0; gj < PE_COL; gj = gj + 1) begin : VALID_COL
            assign valid[gj] = en && (calc_cyc_cnt >= PE_ROW + MUL_LAT + MEM_LAT + gj)
                                  && (calc_cyc_cnt <  PE_ROW + MUL_LAT + MEM_LAT + gj + LAYER_HW);
        end
    endgenerate

endmodule
