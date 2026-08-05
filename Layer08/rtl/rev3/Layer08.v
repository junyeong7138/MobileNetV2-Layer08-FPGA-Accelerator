`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 02:31:39
// Design Name: 
// Module Name: Layer08
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

/*
layer08_top
├── seq_fsm            (IDLE>PW1>DW>PW2>DONE, start/done 핸드셰이크)
├── mem_data           (활성: 입력·중간·출력, Q3.12/UQ3.13)
├── mem_weight         (3단계 가중치 전체)
├── pw_engine          (PW1/PW2 설정 교체 재사용)
│   ├── ctrl_fsm       (LOAD→CALC→DRAIN, 카운터 3개)
│   ├── skew_regs
│   ├── pe_array (SA)  ← 준영 님 그림의 SA
│   │   └── pe × 64    ← 준영 님 그림의 PE
│   ├── accum_buffer   (8뱅크×196×32b, 내부)
│   └── post_proc      ← BN·ReLU6가 여기로 (+재양자화, residual)
└── dw_engine
    ├── line_buffer
    ├── dw_mac         (3×3 윈도우)
    └── post_proc      (pw와 동일 모듈 재사용)
*/

module Layer08 (
    // ------- input -------
    clk,
    rst,

    start,

    din,
    addr,

    // ------- output -------
    done,

    out_valid,      // 완성값 스트림 (8레인) — 검증/파형 분석용 전체 노출
    out_data,       // ★제출판: 32b 누산값 × 8레인
    out_pos         // 위치 인덱스 (0~195) × 8레인
);
    // ==========================================================
    localparam DATA_W   = 16;   // 활성/가중치 폭
    localparam ACC_W    = 32;   // 부분합 폭
    localparam DATA_ROW = 14;   // 입력 데이터 가로
    localparam DATA_COL = 14;   // 입력 데이터 세로
    localparam PE1_ROW  = 8;    // step1 pointwise SA 행 수
    localparam PE1_COL  = 8;    // step1 pointwise SA 열 수
    localparam PE2_ROW  = 9;    // step2 depthwise SA 행 수
    localparam PE2_COL  = 1;    // step2 depthwise SA 열 수

    // ------- input -------
    input               clk;
    input               rst;

    input               start;

    input   [15:0]      din;
    input   [15:0]      addr;

    // ------- output -------
    output                      done;

    output  [PE1_COL-1:0]        out_valid;
    output  [PE1_COL*ACC_W-1:0]  out_data;
    output  [PE1_COL*16-1:0]     out_pos;

    // ==========================================================
    // seq_fsm (IDLE→PW1→DW→PW2→DONE) — 진행 중
    localparam IDLE     = 3'b000;
    localparam PW1      = 3'b001;
    localparam DW       = 3'b010;
    localparam PW2      = 3'b011;
    localparam DONE     = 3'b100;

    reg     [ 2:0]      c_state, n_state;

    always @(posedge clk or posedge rst) begin
        if(rst) c_state <= IDLE;
        else    c_state <= n_state;
    end

    always @(*) begin
        n_state = c_state;
        case(c_state)
            IDLE: begin
                n_state = (start == 1'b1)?  PW1 :
                                            IDLE;
            end

            // TODO: PW1 →(pw_done)→ DW →(dw_done)→ PW2 →(pw_done)→ DONE
        endcase
    end

    // ==========================================================
    // 메모리 — A: 입력 활성 버퍼(128b×1,568), B: 가중치 버퍼(128b×3,072)
    //   읽기 포트(B포트)는 pw_engine이 주소/enable을 구동 (메모리마다 독립!)
    //   쓰기 포트(A포트)는 현재 비활성 — coe 초기화로 대체.
    //     TODO: 외부 로딩 경로(din/addr) 연결은 하드웨어 데이터 교체 단계에서.
    //   ⚠ IP 설정: Primitives Output Register OFF (읽기 지연 1클럭 전제 — MEM_LAT=1)

    wire                        x_rd_en, w_rd_en;
    wire    [15:0]              x_rd_addr, w_rd_addr;
    wire    [PE1_ROW*DATA_W-1:0] x_mem_dout;     // 같은 위치의 8채널 패킹
    wire    [PE1_COL*DATA_W-1:0] w_mem_dout;     // 한 행의 8열 패킹

    blk_mem_input_buffer_128b_1568 u_mem_input (
        // Write (비활성)
        .clka           (clk),
        .ena            (1'b0),
        .wea            (1'b0),
        .addra          (11'd0),
        .dina           ({PE1_ROW*DATA_W{1'b0}}),

        // Read — pw_engine 구동
        .clkb           (clk),
        .enb            (x_rd_en),
        .addrb          (x_rd_addr[10:0]),
        .doutb          (x_mem_dout)
    );

    blk_mem_weight_buffer_128b_3072 u_mem_weight (
        // Write (비활성)
        .clka           (clk),
        .ena            (1'b0),
        .wea            (1'b0),
        .addra          (12'd0),
        .dina           ({PE1_COL*DATA_W{1'b0}}),

        // Read — pw_engine 구동
        .clkb           (clk),
        .enb            (w_rd_en),
        .addrb          (w_rd_addr[11:0]),
        .doutb          (w_mem_dout)
    );

    // ==========================================================
    // pw_engine

    wire                        pw_done;
    wire    [PE1_COL-1:0]       pw_out_valid;   // 완성값 스트림 (8레인)
    wire    [PE1_COL*ACC_W-1:0] pw_out_data;    // ★제출판: 32b conv 누산값 (Post_Proc 복원 시 DATA_W로)
    wire    [PE1_COL*16-1:0]    pw_out_pos;

    Pointwise_Conv #(
        .DATA_W         (DATA_W         ),
        .ACC_W          (ACC_W          ),
        .DATA_ROW       (DATA_ROW       ),
        .DATA_COL       (DATA_COL       ),
        .PE_ROW         (PE1_ROW        ),
        .PE_COL         (PE1_COL        )
        // N_CTILE/N_FTILE: PW1=8/48, PW2=48/8 — seq_fsm 설정 레지스터로 교체 예정
    ) u_Pointwise_Conv (
        // ------- input -------
        .clk            (clk            ),
        .rst            (rst            ),

        .start          (start          ),        // TODO: seq_fsm의 pw_start로 교체

        .x_mem_dout     (x_mem_dout     ),
        .w_mem_dout     (w_mem_dout     ),

        // ------- output -------
        .x_rd_en        (x_rd_en        ),
        .x_rd_addr      (x_rd_addr      ),
        .w_rd_en        (w_rd_en        ),
        .w_rd_addr      (w_rd_addr      ),

        .done           (pw_done        ),

        .out_valid      (pw_out_valid   ),  // 완성된 tile valid
        .out_data       (pw_out_data    ),
        .out_pos        (pw_out_pos     )
    );

    // ==========================================================
    // dw_engine

    wire                        dw_done;
    wire    [PE2_COL-1:0]       dw_out_valid;   // 완성값 스트림 (8레인)
    wire    [PE2_COL*ACC_W-1:0] dw_out_data;    // ★제출판: 32b conv 누산값 (Post_Proc 복원 시 DATA_W로)
    wire    [PE2_COL*16-1:0]    dw_out_pos;

    Depthwise_Conv #(
        .DATA_W         (DATA_W         ),
        .ACC_W          (ACC_W          ),
        .DATA_ROW       (DATA_ROW       ),
        .DATA_COL       (DATA_COL       ),
        .PE_ROW         (PE2_ROW        ),
        .PE_COL         (PE2_COL        )
        // N_CTILE/N_FTILE: PW1=8/48, PW2=48/8 — seq_fsm 설정 레지스터로 교체 예정
    ) u_Depthwise_Conv (
        // ------- input -------
        .clk            (clk            ),
        .rst            (rst            ),

        .start          (start          ),        // TODO: seq_fsm의 pw_start로 교체

        .x_mem_dout     (x_mem_dout     ),
        .w_mem_dout     (w_mem_dout     ),

        // ------- output -------
        .x_rd_en        (x_rd_en        ),
        .x_rd_addr      (x_rd_addr      ),
        .w_rd_en        (w_rd_en        ),
        .w_rd_addr      (w_rd_addr      ),

        .done           (dw_done        ),

        .out_valid      (dw_out_valid   ),
        .out_data       (dw_out_data    ),
        .out_pos        (dw_out_pos     )
    );

    // 검증 단계: 완성값 스트림 전체를 톱 포트로 노출.
    //   ① 전 레인이 "사용됨"이 되어 합성 트리밍(레인1~7 누산 뱅크 제거) 방지
    //   ② TB가 내부 계층 참조 없이 포트만으로 전수 채점 가능 (post-synth 동일 채점)
    //   TODO: DW 엔진 단계에서 이 포트들을 내부 중간 버퍼(384×196×16b) 쓰기로 교체.
    assign done      = pw_done;
    assign out_valid = pw_out_valid;
    assign out_data  = pw_out_data;
    assign out_pos   = pw_out_pos;

endmodule
