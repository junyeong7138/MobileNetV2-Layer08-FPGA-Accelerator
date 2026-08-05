`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Depthwise_Conv
//////////////////////////////////////////////////////////////////////////////////

//==========================================================
// Depthwise_Conv (dw_engine) — 노션 4-1 §3 (rev3 독립 실습)
//
//   Ctrl_FSM_DW ──(load_mode/en/din_valid/valid/카운터·좌표)──▶ 주소 생성 + 데이터패스
//
//   A 메모리(외부, 16b×75,264) ◀── x_rd_addr/en ──┐
//        x_mem_dout ─▶ Window_Gen(31단 지연선+마스킹, 9탭)
//                       ─▶ Skew_Regs(행 i를 i클럭 지연)
//                        ─▶ SystolicArray(9×1, X_UNSIGNED=1) ─▶ psum_out(32b)
//   B 메모리(외부, 16b×3,456) ◀── w_rd_addr/en ──┘   ▲ w_in = w_mem_dout (LOAD 9클럭 shift-in)
//
//   psum_out ─(valid 게이트)─▶ out_valid/out_data(32b)/out_pos
//   (Accum_Buffer 없음 — 9탭 합이 한 패스에 완성. BN2·ReLU6는 후속 IP 실습)
//
// 메모리 읽기 지연(MEM_LAT=1클럭) 정렬 — PW와 동일 방식:
//   주소는 FSM 신호(현재 상태)로 발행, 데이터는 1클럭 뒤 도착하므로
//   Window_Gen/SA에는 din_valid/load_mode/en의 "1클럭 지연판"을 물린다.
//   win_row/win_col도 같은 1클럭 지연판 — 탭과 마스킹 좌표가 같은 시간축.
//   (정확한 ±1은 통합 TB에서 확정 — Window_Gen.v 헤더 계약 3번)
//
// 주소 규칙 (COE 패킹과 1:1, 채널-major):
//   A: x_addr = ch_cnt×196 + rd_cnt   (rd_cnt는 195 클램프 — 더미 구간 주소 정지)
//   B: w_addr = ch_cnt×9   + load_cnt (COE가 탭 역순 저장 전제 — shift-in 순서)
//==========================================================
module Depthwise_Conv #(
    parameter DATA_W   = 16,    // 활성/가중치 폭 (입력 UQ3.13 unsigned, 가중치 2^-n signed)
    parameter ACC_W    = 32,    // 누산 폭 — 32b signed 통일
    parameter DATA_ROW = 14,    // 채널 가로
    parameter DATA_COL = 14,    // 채널 세로
    parameter PE_ROW   = 9,     // SA 행 수 = 3×3 탭 수
    parameter PE_COL   = 1,     // SA 열 수
    parameter N_CH     = 384,   // 채널 수
    parameter MUL_LAT  = 4,     // 곱셈기 IP 파이프라인 지연 (mult_gen_1도 4단 필수)
    parameter MEM_LAT  = 1,     // 버퍼 BRAM 읽기 지연
    parameter WG_LAT   = 1,     // Window_Gen 등록 파이프 깊이
    parameter PREFILL_LEN = 16  // Window_Gen 지연선 선충전
)(
    // ------- input -------
    clk,
    rst,

    start,

    x_mem_dout,     // A 메모리 읽기 데이터 (픽셀 1개, UQ3.13)
    w_mem_dout,     // B 메모리 읽기 데이터 (탭 가중치 1개)

    // ------- output -------
    x_rd_en,        // A 메모리 읽기 포트 제어
    x_rd_addr,
    w_rd_en,        // B 메모리 읽기 포트 제어
    w_rd_addr,

    done,

    out_valid,      // 완성값 스트림 (단일 레인)
    out_data,       // 32b 누산값 (순수 DW conv 결과 — BN·ReLU6 전)
    out_pos         // 위치 인덱스 (0~195), 채널 = ch_cnt
);
    // ==========================================================
    // ------- input -------
    input                       clk;
    input                       rst;

    input                       start;

    input   [DATA_W-1:0]        x_mem_dout;
    input   [DATA_W-1:0]        w_mem_dout;

    // ------- output -------
    output                      x_rd_en;
    output  [16:0]              x_rd_addr;      // 75,264 > 65,536 → 17b
    output                      w_rd_en;
    output  [15:0]              w_rd_addr;

    output                      done;

    output                      out_valid;
    output  [ACC_W-1:0]         out_data;
    output  [15:0]              out_pos;

    localparam LAYER_HW = DATA_ROW*DATA_COL;                    // 위치 수 (196)
    localparam OFFSET   = WG_LAT + PE_ROW + MUL_LAT + MEM_LAT;  // FSM valid 오프셋과 동일 상수

    // ==========================================================
    // 제어 신호 — 전부 Ctrl_FSM_DW가 생성 (상태 인코딩은 FSM 내부에만 존재)

    wire                        load_mode, en, valid, din_valid;
    wire    [15:0]              load_cnt, calc_cyc_cnt;
    wire    [15:0]              ch_cnt, rd_cnt;
    wire    [ 3:0]              win_row, win_col;

    Ctrl_FSM_DW #(
        .PE_ROW             (PE_ROW      ),
        .PE_COL             (PE_COL      ),
        .LAYER_HW           (LAYER_HW    ),
        .N_CH               (N_CH        ),
        .PREFILL_LEN        (PREFILL_LEN ),
        .WG_LAT             (WG_LAT      ),
        .IMG_W              (DATA_ROW    ),
        .MUL_LAT            (MUL_LAT     ),
        .MEM_LAT            (MEM_LAT     )
    ) u_Ctrl_FSM_DW (
        // ------- input -------
        .clk                (clk         ),
        .rst                (rst         ),

        .start              (start       ),

        // ------- output -------
        .load_mode          (load_mode   ),
        .en                 (en          ),
        .valid              (valid       ),
        .done               (done        ),

        .load_cnt           (load_cnt    ),
        .calc_cyc_cnt       (calc_cyc_cnt),
        .ch_cnt             (ch_cnt      ),
        .rd_cnt             (rd_cnt      ),
        .win_row            (win_row     ),
        .win_col            (win_col     ),
        .din_valid          (din_valid   )
    );

    // ==========================================================
    // 메모리 읽기 주소 생성
    //   B: LOAD 구간,         addr = ch_cnt×9   + load_cnt
    //   A: PREFILL+CALC 구간, addr = ch_cnt×196 + rd_cnt (195 클램프는 FSM 몫)

    assign w_rd_en   = load_mode;
    assign w_rd_addr = ch_cnt*PE_ROW + load_cnt;

    assign x_rd_en   = din_valid;
    assign x_rd_addr = ch_cnt*LAYER_HW + rd_cnt;

    // 읽기 지연 1클럭(MEM_LAT) 정렬 — 데이터가 도착하는 사이클에 등록/동작하도록
    reg                 load_mode_d, en_d, din_valid_d;
    reg     [3:0]       win_row_d, win_col_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            load_mode_d <= 1'b0;
            en_d        <= 1'b0;
            din_valid_d <= 1'b0;
            win_row_d   <= 4'd0;
            win_col_d   <= 4'd0;
        end
        else begin
            load_mode_d <= load_mode;
            en_d        <= en;
            din_valid_d <= din_valid;
            win_row_d   <= win_row;
            win_col_d   <= win_col;
        end
    end

    // ==========================================================
    // 데이터패스: A 메모리 → Window_Gen(9탭+마스킹) → skew 계단 → SA
    //             B 메모리 → SA (shift-in)

    wire    [DATA_W-1:0]        p1, p2, p3, p4, p5, p6, p7, p8, p9;

    Window_Gen #(
        .DATA_W         (DATA_W  ),
        .IMG_W          (DATA_ROW)
    ) u_Window_Gen (
        .clk            (clk        ),
        .rst            (rst        ),

        .din_valid      (din_valid_d),      // 메모리 지연 1클럭 정렬판
        .din            (x_mem_dout ),

        .win_row        (win_row_d  ),      // 탭과 같은 시간축의 좌표
        .win_col        (win_col_d  ),

        .pixel1 (p1), .pixel2 (p2), .pixel3 (p3),
        .pixel4 (p4), .pixel5 (p5), .pixel6 (p6),
        .pixel7 (p7), .pixel8 (p8), .pixel9 (p9)
    );

    // 9탭 → SA 행 패킹 (행 0 = 탭 a … 행 8 = 탭 i — 벡터 하위가 행 0)
    //   Skew_Regs가 행 i를 i클럭 지연 → psum 사다리가 계단을 도로 흡수
    wire    [PE_ROW*DATA_W-1:0] taps = {p9, p8, p7, p6, p5, p4, p3, p2, p1};
    wire    [PE_ROW*DATA_W-1:0] x_in;

    Skew_Regs #(
        .DATA_W         (DATA_W),
        .PE_ROW         (PE_ROW)
    ) u_Skew_Regs (
        .clk            (clk  ),
        .rst            (rst  ),

        .din            (taps ),
        .dout           (x_in )
    );

    wire    [PE_COL*ACC_W-1:0]  psum_out;

    SystolicArray #(
        .DATA_W         (DATA_W),
        .ACC_W          (ACC_W ),
        .PE_ROW         (PE_ROW),
        .PE_COL         (PE_COL),
        .X_UNSIGNED     (1)                 // DW: x = UQ3.13 unsigned × w signed (mult_gen_1)
    ) u_SystolicArray (
        .clk            (clk        ),
        .rst            (rst        ),

        .en             (en_d       ),      // 메모리 지연 1클럭 정렬판
        .load_mode      (load_mode_d),

        .x_in           (x_in       ),
        .w_in           (w_mem_dout ),

        .psum_out       (psum_out   )
    );

    // ==========================================================
    // 출력 — Accum_Buffer 없음: 열 바닥 psum이 곧 완성값 (BN2·ReLU6는 후속 IP 실습)

    assign out_valid = valid;
    assign out_data  = psum_out;
    assign out_pos   = calc_cyc_cnt - OFFSET;   // valid 구간에서 0~195

endmodule
