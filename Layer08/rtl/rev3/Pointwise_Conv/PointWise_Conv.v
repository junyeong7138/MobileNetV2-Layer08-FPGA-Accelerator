`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/08/02 02:34:19
// Design Name:
// Module Name: Pointwise_Conv
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
// Pointwise_Conv (pw_engine) — 노션 스펙 §6.1
//
//   Ctrl_FSM ──(load_mode/en/valid/카운터)──▶ 주소 생성 + SystolicArray
//
//   A 메모리(외부) ◀── x_rd_addr/en ──┐
//        x_mem_dout ─▶ Skew_Regs ─▶ x_in ─▶ SystolicArray ─▶ psum_out
//   B 메모리(외부) ◀── w_rd_addr/en ──┘        ▲ w_in = w_mem_dout
//
//   psum_out ─▶ Accum_Buffer(8뱅크×196×32b, valid/first_ch_tile 게이트)
//               └─(마지막 채널 타일 완성값 스트림)─▶ Post_Proc(bias→ReLU6→≫15)
//                                                    └─▶ out_valid/out_data/out_pos
//   bias ROM(256b×48, $readmemh) ─▶ Post_Proc (필터 타일당 8레인)
//
// 메모리 읽기 지연(MEM_LAT=1클럭) 정렬:
//   주소는 FSM 신호(현재 상태)로 발행, 데이터는 1클럭 뒤 도착하므로
//   SA에는 load_mode/en의 "1클럭 지연판"을 물린다.
//   Ctrl_FSM valid 윈도우의 MEM_LAT 오프셋과 세트로 맞아떨어진다.
//
// PW1(64→384) / PW2(384→64)는 파라미터(N_CTILE/N_FTILE)만 바꿔 재사용.
//==========================================================
module Pointwise_Conv #(
    parameter DATA_W   = 16,    // 활성/가중치 폭 (Q3.12, UQ3.13, 2^-n 스케일)
    parameter ACC_W    = 32,    // 부분합 폭 — 32b signed 통일 (스펙 §4.4)
    parameter DATA_ROW = 14,    // 입력 데이터 가로
    parameter DATA_COL = 14,    // 입력 데이터 세로
    parameter PE_ROW   = 8,     // SA 행 수 (입력 채널 타일)
    parameter PE_COL   = 8,     // SA 열 수 (출력 필터 타일)
    parameter N_CTILE  = 8,     // 채널 타일 수 (PW1: 64/8=8,  PW2: 384/8=48)
    parameter N_FTILE  = 48,    // 필터 타일 수 (PW1: 384/8=48, PW2: 64/8=8)
    parameter MUL_LAT  = 4,     // 곱셈기 IP 파이프라인 지연
    parameter MEM_LAT  = 1,     // 버퍼 BRAM 읽기 지연
    parameter REQ_SHIFT = 15,   // 재양자화 시프트 (PW1: 15, PW2: 15)
    parameter ACC_FRAC  = 28,   // 누산기 소수부 (PW1: 12+16=28, PW2: 13+14=27)
    parameter RELU_EN   = 1     // PW1: 1 (ReLU6), PW2: 0 (linear)
    // Post_Proc 복원 시: 위 줄에 쉼표 추가 후 아래 주석 해제
    // , parameter BIAS_INIT = "../Data/Weight/layer08_expand_bias_q28_256x48.hex"
)(
    // ------- input -------
    clk,
    rst,

    start,

    x_mem_dout,     // A 메모리 읽기 데이터 (같은 위치의 8채널 패킹)
    w_mem_dout,     // B 메모리 읽기 데이터 (한 행의 8열 패킹)

    // ------- output -------
    x_rd_en,        // A 메모리 읽기 포트 제어
    x_rd_addr,
    w_rd_en,        // B 메모리 읽기 포트 제어
    w_rd_addr,

    done,

    out_valid,      // 후처리 완료 스트림 (8레인)
    out_data,       // UQ3.13 (PW1) — 채널 = filter_tile×8 + 레인
    out_pos         // 위치 인덱스 (0~195)
);
    // ==========================================================
    // ------- input -------
    input                       clk;
    input                       rst;

    input                       start;

    input   [PE_ROW*DATA_W-1:0] x_mem_dout;
    input   [PE_COL*DATA_W-1:0] w_mem_dout;

    // ------- output -------
    output                      x_rd_en;
    output  [15:0]              x_rd_addr;
    output                      w_rd_en;
    output  [15:0]              w_rd_addr;

    output                      done;

    output  [PE_COL-1:0]        out_valid;
    output  [PE_COL*ACC_W-1:0]  out_data;   // ★제출판: 32b 누산값(순수 conv 결과) 그대로 출력
                                            //   Post_Proc 복원 시 [PE_COL*DATA_W-1:0]으로 되돌릴 것
    output  [PE_COL*16-1:0]     out_pos;

    localparam LAYER_HW = DATA_ROW*DATA_COL;    // 위치 수 (196)

    // ==========================================================
    // 제어 신호 — 전부 Ctrl_FSM이 생성 (상태 인코딩은 FSM 내부에만 존재)

    wire                        load_mode, en;
    wire    [PE_COL-1:0]        valid;
    wire    [15:0]              load_cnt, calc_cyc_cnt;
    wire    [15:0]              ch_tile_cnt, filter_tile_cnt;
    wire                        first_ch_tile, last_ch_tile;

    Ctrl_FSM #(
        .PE_ROW             (PE_ROW         ),
        .PE_COL             (PE_COL         ),
        .LAYER_HW           (LAYER_HW       ),
        .N_CTILE            (N_CTILE        ),
        .N_FTILE            (N_FTILE        ),
        .MUL_LAT            (MUL_LAT        ),
        .MEM_LAT            (MEM_LAT        )
    ) u_Ctrl_FSM (
        // ------- input -------
        .clk                (clk            ),
        .rst                (rst            ),

        .start              (start          ),

        // ------- output -------
        .load_mode          (load_mode      ),
        .en                 (en             ),
        .valid              (valid          ),
        .done               (done           ),

        .load_cnt           (load_cnt       ),
        .calc_cyc_cnt       (calc_cyc_cnt   ),
        .ch_tile_cnt        (ch_tile_cnt    ),
        .filter_tile_cnt    (filter_tile_cnt),
        .first_ch_tile      (first_ch_tile  ),
        .last_ch_tile       (last_ch_tile   )
    );

    // ==========================================================
    // 메모리 읽기 주소 생성 (COE 패킹 규칙과 1:1 — make_input_coe/make_weight_coe 참조)
    //   B: LOAD 구간, addr = (필터타일×N_CTILE + 채널타일)×PE_ROW + load_cnt
    //      (COE가 행 역순 저장이라 주소 증가 읽기만 하면 shift-in 순서가 맞음)
    //   A: CALC 구간, addr = 채널타일×LAYER_HW + 위치(calc_cyc_cnt)

    assign w_rd_en   = load_mode;
    assign w_rd_addr = (filter_tile_cnt*N_CTILE + ch_tile_cnt)*PE_ROW + load_cnt;

    assign x_rd_en   = en && (calc_cyc_cnt < LAYER_HW);
    assign x_rd_addr = ch_tile_cnt*LAYER_HW + calc_cyc_cnt;

    // 읽기 지연 1클럭(MEM_LAT) 정렬 — 데이터가 도착하는 사이클에 SA가 동작하도록
    reg                 load_mode_d, en_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            load_mode_d <= 1'b0;
            en_d        <= 1'b0;
        end
        else begin
            load_mode_d <= load_mode;
            en_d        <= en;
        end
    end

    // ==========================================================
    // 데이터패스: A 메모리 → skew 계단 → SA, B 메모리 → SA (shift-in)

    wire    [PE_ROW*DATA_W-1:0] x_in;

    Skew_Regs #(
        .DATA_W         (DATA_W),
        .PE_ROW         (PE_ROW)
    ) u_Skew_Regs (
        .clk            (clk       ),
        .rst            (rst       ),

        .din            (x_mem_dout),
        .dout           (x_in      )
    );

    wire    [PE_COL*ACC_W-1:0]  psum_out;

    SystolicArray #(
        .DATA_W         (DATA_W),
        .ACC_W          (ACC_W ),
        .PE_ROW         (PE_ROW),
        .PE_COL         (PE_COL),
        .X_UNSIGNED     (0)                 // 0이면 signed 곱셈기
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
    // 누산 버퍼 — 채널 타일 8회 누산, 마지막 타일 완성값을 스트림으로 배출

    wire    [PE_COL-1:0]        acc_valid;
    wire    [PE_COL*ACC_W-1:0]  acc_data;
    wire    [PE_COL*16-1:0]     acc_pos;

    Accum_Buffer #(
        .ACC_W          (ACC_W   ),
        .PE_COL         (PE_COL  ),
        .DEPTH          (LAYER_HW),
        .ADDR_OFFSET    (PE_ROW + MUL_LAT + MEM_LAT)    // valid 윈도우 시작 = de-skew 기준
    ) u_Accum_Buffer (
        .clk            (clk          ),
        .rst            (rst          ),

        .calc_cyc_cnt   (calc_cyc_cnt ),
        .valid          (valid        ),
        .first_ch_tile  (first_ch_tile),
        .last_ch_tile   (last_ch_tile ),

        .psum_in        (psum_out     ),

        .out_valid      (acc_valid    ),    // 완성된 tile valid 신호
        .out_acc        (acc_data     ),
        .out_pos        (acc_pos      )
    );

    // ==========================================================
    // ★제출판: 이번 주 과제 범위는 pointwise conv까지 — BN(bias)·ReLU6 제외.
    //   누산 완료된 32b conv 결과를 그대로 출력한다 (Post_Proc.v는 Vivado 미포함).
    //   다음 단계에서 아래 주석 블록을 복원하면 bias→ReLU6→재양자화 경로가 살아남.

    assign out_valid = acc_valid;
    assign out_data  = acc_data;    // 32b 누산값 (BN 폴딩 가중치 기준 Σx·w)
    assign out_pos   = acc_pos;

    // ==========================================================
    // // bias ROM — 필터 타일당 8레인(256b) × N_FTILE, 타일 동안 값 고정
    // //   Vivado: 48깊이 comb 읽기 → distributed ROM 추론, $readmemh 초기화
    //
    // reg     [PE_COL*ACC_W-1:0]  bias_mem [0:N_FTILE-1];
    //
    // initial $readmemh(BIAS_INIT, bias_mem);
    //
    // wire    [PE_COL*ACC_W-1:0]  bias_word = bias_mem[filter_tile_cnt];
    //
    // // ==========================================================
    // // 후처리 — bias → ReLU6 → 재양자화(≫15, round-half-up) → 포화
    // //   (검증 완료: 2026-08-02, 최종 출력 75,264개 fixp C 모델과 비트 일치)
    //
    // Post_Proc #(
    //     .DATA_W         (DATA_W   ),
    //     .ACC_W          (ACC_W    ),
    //     .LANES          (PE_COL   ),
    //     .REQ_SHIFT      (REQ_SHIFT),
    //     .ACC_FRAC       (ACC_FRAC ),
    //     .RELU_EN        (RELU_EN  )
    // ) u_Post_Proc (
    //     .clk            (clk      ),
    //     .rst            (rst      ),
    //
    //     .in_valid       (acc_valid),
    //     .in_acc         (acc_data ),
    //     .in_pos         (acc_pos  ),
    //
    //     .bias_in        (bias_word),
    //
    //     .out_valid      (out_valid),
    //     .out_data       (out_data ),      // 복원 시 out_data 폭을 DATA_W 기준으로 변경
    //     .out_pos        (out_pos  )
    // );

endmodule
