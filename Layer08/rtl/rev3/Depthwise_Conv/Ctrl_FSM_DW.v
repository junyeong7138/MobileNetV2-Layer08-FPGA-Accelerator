`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Ctrl_FSM_DW — PW Ctrl_FSM의 설계 규칙
// (상태 인코딩은 내부에만, 카운터는 c_state 기준, 출력은 n_state 기준 레지스터)을 그대로 가져오되 구조만 단순화:
//
// - 상태: IDLE → LOAD(9클럭) → PREFILL(16클럭, Window_Gen 지연선 채움)     [rev3]
//         → CALC(196클럭, 클럭당 윈도우 1개) → DRAIN(파이프 배출)
//         → 분기(ch_cnt≠383이면 LOAD, 끝이면 DONE)
//
// - valid 윈도우 1개: calc_cyc_cnt ∈ [OFFSET, OFFSET+196),
//   OFFSET = WG_LAT 1 + PE_ROW 9 + MUL_LAT 4 + MEM_LAT 1 = 15 (초기값)
//   — 정확한 값은 통합 TB 파형에서 ±1 보정 후 상수로 계약 (MUL_LAT 방식 그대로)
//
// - Window_Gen 계약 (Window_Gen.v 헤더 참조):                              [rev3]
//   din_valid는 PREFILL+CALC 동안 연속 1. CALC 후반 15클럭은 자동으로 더미
//   시프트 구간 — rd_cnt만 195에서 클램프되어 주소가 멈추고, stale 데이터가
//   닿는 탭은 전부 마스킹 자리라 무해.
//   MEM_LAT 1클럭 정렬은 톱에서 din_valid 지연판으로 흡수 (PW의 load_mode/en 지연판 방식).
//////////////////////////////////////////////////////////////////////////////////

module Ctrl_FSM_DW #(
    parameter PE_ROW      = 9,     // SA 행 수 = LOAD 클럭 수 (3×3 = 9탭)
    parameter PE_COL      = 1,     // SA 열 수
    parameter LAYER_HW    = 196,   // 채널당 출력 위치 수 (14x14)
//  parameter N_CTILE     = 8,     // [rev3 삭제] 입력 채널 타일 수 — DW는 채널 간 누산 없음
//  parameter N_FTILE     = 48,    // [rev3 삭제] 출력 필터 타일 수 — DW는 단일 채널 루프
    parameter N_CH        = 384,   // [rev3] 채널 수 (단일 루프 0~383)
    parameter PREFILL_LEN = 16,    // [rev3] Window_Gen 지연선 선충전 클럭 수
    parameter WG_LAT      = 1,     // [rev3] Window_Gen 등록 파이프 깊이 (지연선 1단)
    parameter IMG_W       = 14,    // [rev3] 행 폭 (win_row/win_col 랩 기준)
    parameter MUL_LAT     = 4,     // PE 곱셈기 IP 파이프라인 지연 (mult_gen_0 Pipeline Stages)
    parameter MEM_LAT     = 1      // 버퍼 BRAM 읽기 지연 (Primitives Output Register OFF = 1클럭)
)(
    // ------- input -------
    clk,
    rst,

    start,

    // ------- output -------
    load_mode,          // LOAD 구간 1 — SA shift-in
    en,                 // CALC+DRAIN 구간 1 — SA 파이프라인 진행
    valid,              // psum 유효 윈도우 (단일 열)
    done,               // 전체 채널 완료 1클럭 펄스

    load_cnt,           // LOAD 진행 카운터  (가중치 주소: ch_cnt*9 + load_cnt)
    calc_cyc_cnt,       // CALC+DRAIN 카운터 (valid·out_pos 기준)
    ch_cnt,             // [rev3] 현재 채널 (0~383) — 주소 베이스: ch_cnt*196 / ch_cnt*9
    rd_cnt,             // [rev3] 픽셀 읽기 카운터 (0~195 클램프) — x 주소 = ch_cnt*196 + rd_cnt
    win_row,            // [rev3] 방출 중인 윈도우 좌표 (Window_Gen 마스킹용)
    win_col,            // [rev3]
    din_valid           // [rev3] Window_Gen 체인 전진 게이트 (PREFILL+CALC 연속 1)
//  ch_tile_cnt,        // [rev3 삭제] 현재 채널 타일 — 2중 타일 루프 없음
//  filter_tile_cnt,    // [rev3 삭제] 현재 필터 타일
//  first_ch_tile,      // [rev3 삭제] 누산 버퍼 bypass — Accum_Buffer 자체가 없음
//  last_ch_tile        // [rev3 삭제] 완성값 전달 구간 — DW는 매 채널이 곧 완성
);
    // ==========================================================
    // ------- input -------
    input                   clk;
    input                   rst;

    input                   start;

    // ------- output -------
    output                  load_mode;
    output                  en;
    output                  valid;          // [rev3] 열 1개 — [PE_COL-1:0] → 단일 비트
    output                  done;

    output  [15:0]          load_cnt;
    output  [15:0]          calc_cyc_cnt;
    output  [15:0]          ch_cnt;         // [rev3]
    output  [15:0]          rd_cnt;         // [rev3]
    output  [ 3:0]          win_row;        // [rev3]
    output  [ 3:0]          win_col;        // [rev3]
    output                  din_valid;      // [rev3]
//  output  [15:0]          ch_tile_cnt;    // [rev3 삭제]
//  output  [15:0]          filter_tile_cnt;// [rev3 삭제]
//  output                  first_ch_tile;  // [rev3 삭제]
//  output                  last_ch_tile;   // [rev3 삭제]

    // ==========================================================
    localparam IDLE     = 3'b000;
    localparam LOAD     = 3'b001;
    localparam PREFILL  = 3'b010;   // [rev3] 신규 — 이하 인코딩 한 칸씩 밀림 (외부 비노출이라 무해)
    localparam CALC     = 3'b011;
    localparam DRAIN    = 3'b100;
    localparam DONE     = 3'b101;

    // [rev3] 마지막 윈도우(calc_cyc_cnt=195)의 psum이 파이프(OFFSET)를 다 빠져나올 때까지 + 여유 1
    //   (PW의 RMW 여유 +3은 Accum_Buffer가 없으므로 불필요)
    //                      1(WG_LAT) + 9(PE_ROW) + 4(MUL_LAT) + 1(MEM_LAT) = 15
    localparam OFFSET   = WG_LAT + PE_ROW + MUL_LAT + MEM_LAT;
    localparam CYC_END  = LAYER_HW + OFFSET + 1;
//  localparam CYC_END  = LAYER_HW + PE_ROW + PE_COL + MUL_LAT + MEM_LAT + 1;   // [rev3 삭제] PW 판

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

            LOAD: begin     // 가중치 세팅 클럭 (3×3 = 9탭이라 PE_ROW = 9클럭)
                n_state = (load_cnt == PE_ROW-1)?   PREFILL :   // [rev3] CALC → PREFILL
                                                    LOAD;
            end

            PREFILL: begin  // [rev3] 신규 — 지연선 선충전 (읽기만 진행, 윈도우 방출 없음)
                n_state = (prefill_cnt == PREFILL_LEN-1)?   CALC :
                                                            PREFILL;
            end

            CALC: begin     // 14x14라서 196 클럭 = 클럭당 윈도우 1개
                n_state = (calc_cyc_cnt == LAYER_HW-1)?     DRAIN :
                                                            CALC;
            end

            DRAIN: begin
                if (calc_cyc_cnt == CYC_END) begin
                    if (ch_cnt != N_CH-1)   n_state = LOAD;     // [rev3] 다음 채널 (단일 루프)
                    else                    n_state = DONE;     // 전부 끝
//                  if      (ch_tile_cnt != N_CTILE-1)      n_state = LOAD;  // [rev3 삭제] 다음 채널 타일
//                  else if (filter_tile_cnt != N_FTILE-1)  n_state = LOAD;  // [rev3 삭제] 다음 필터 타일
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
    reg     [15:0]      prefill_cnt;    // [rev3]

    always @(posedge clk or posedge rst) begin
        if(rst)                         load_cnt <= 16'd0;
        else if (c_state == LOAD)       load_cnt <= load_cnt + 16'd1;
        else                            load_cnt <= 16'd0;
    end

    // [rev3] PREFILL 진행 카운터
    always @(posedge clk or posedge rst) begin
        if(rst)                         prefill_cnt <= 16'd0;
        else if (c_state == PREFILL)    prefill_cnt <= prefill_cnt + 16'd1;
        else                            prefill_cnt <= 16'd0;
    end

    // CALC에서 0부터 세기 시작해 DRAIN까지 이어서 센다 (valid 윈도우의 기준 축)
    always @(posedge clk or posedge rst) begin
        if(rst)                                             calc_cyc_cnt <= 16'd0;
        else if (c_state == CALC || c_state == DRAIN)       calc_cyc_cnt <= calc_cyc_cnt + 16'd1;
        else                                                calc_cyc_cnt <= 16'd0;
    end

    // [rev3] 픽셀 읽기 카운터 — PREFILL+CALC 동안 진행, 195에서 클램프
    //   (클램프 후 CALC 후반 15클럭 = Window_Gen 더미 시프트 구간, 주소만 멈춤)
    reg     [15:0]      rd_cnt;

    always @(posedge clk or posedge rst) begin
        if(rst)                                             rd_cnt <= 16'd0;
        else if (c_state == PREFILL || c_state == CALC) begin
            if (rd_cnt != LAYER_HW-1)                       rd_cnt <= rd_cnt + 16'd1;
        end
        else                                                rd_cnt <= 16'd0;
    end

    // [rev3] 윈도우 좌표 — CALC 동안 랩 카운터 2개 (나누기 14 회로 없이)
    reg     [ 3:0]      win_row, win_col;

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            win_row <= 4'd0;
            win_col <= 4'd0;
        end
        else if (c_state == CALC) begin
            if (win_col == IMG_W-1) begin
                win_col <= 4'd0;
                win_row <= win_row + 4'd1;
            end
            else begin
                win_col <= win_col + 4'd1;
            end
        end
        else begin
            win_row <= 4'd0;
            win_col <= 4'd0;
        end
    end

    // [rev3] 채널 카운터 — DRAIN 종료 시점에 갱신 (단일 루프)
    reg     [15:0]      ch_cnt;

    always @(posedge clk or posedge rst) begin
        if(rst)                                                 ch_cnt <= 16'd0;
        else if (c_state == IDLE)                               ch_cnt <= 16'd0;    // 연산 전 클리어
        else if (c_state == DRAIN && calc_cyc_cnt == CYC_END)   ch_cnt <= ch_cnt + 16'd1;
        // 마지막 채널이면 어차피 DONE→IDLE에서 클리어
    end

//  // [rev3 삭제] 타일 카운터 — DRAIN 종료 시점에 갱신 (PW 2중 루프)
//  reg     [15:0]      ch_tile_cnt, filter_tile_cnt;
//
//  always @(posedge clk or posedge rst) begin
//      if(rst) begin
//          ch_tile_cnt <= 16'd0;
//          filter_tile_cnt <= 16'd0;
//      end
//      else if (c_state == IDLE) begin // 현재 IDLE 상태일때
//          ch_tile_cnt <= 16'd0;       // 연산을 안하니 카운트는 0
//          filter_tile_cnt <= 16'd0;
//      end
//      else if (c_state == DRAIN && calc_cyc_cnt == CYC_END) begin // DRAIN 상태일때 마지막 열이면
//          if (ch_tile_cnt != N_CTILE-1) begin
//              ch_tile_cnt <= ch_tile_cnt + 16'd1;
//          end
//          else begin
//              ch_tile_cnt <= 16'd0;
//              filter_tile_cnt <= filter_tile_cnt + 16'd1;   // 마지막 타일이면 어차피 DONE→IDLE에서 클리어
//          end
//      end
//  end
//
//  assign first_ch_tile = (ch_tile_cnt == 16'd0);
//  assign last_ch_tile  = (ch_tile_cnt == N_CTILE-1);

    // ==========================================================
    // 출력 신호 — n_state 기준 레지스터 (모든 경로에서 값 확정 → 눌러붙음 없음)

    reg                 load_mode, en, done;
    reg                 din_valid;      // [rev3]

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            load_mode   <= 1'b0;
            en          <= 1'b0;
            done        <= 1'b0;
            din_valid   <= 1'b0;                                            // [rev3]
        end
        else begin
            load_mode   <= (n_state == LOAD);
            en          <= (n_state == CALC) || (n_state == DRAIN);   // DRAIN에도 1! (psum 배출)
            done        <= (n_state == DONE);
            din_valid   <= (n_state == PREFILL) || (n_state == CALC);       // [rev3] 연속 1 (계약 1·2번)
        end
    end

    // ==========================================================
    // [rev3] valid — 단일 윈도우 (열이 1개라 열별 generate 불필요)
    //   psum_out은 calc_cyc_cnt ∈ [OFFSET, OFFSET+LAYER_HW) 에서 유효.
    //   PREFILL이 CALC 앞에 끼어 있어 LOAD 잔여물(stale 곱)은 자연히 윈도우 밖.

    assign valid = en && (calc_cyc_cnt >= OFFSET)
                      && (calc_cyc_cnt <  OFFSET + LAYER_HW);

//  // [rev3 삭제] 열별 valid 윈도우 (PW 8열 판, 스펙 §4.3)
//  genvar gj;
//  generate
//      for (gj = 0; gj < PE_COL; gj = gj + 1) begin : VALID_COL
//          assign valid[gj] = en && (calc_cyc_cnt >= PE_ROW + MUL_LAT + MEM_LAT + gj)
//                                && (calc_cyc_cnt <  PE_ROW + MUL_LAT + MEM_LAT + gj + LAYER_HW);
//      end
//  endgenerate

endmodule
