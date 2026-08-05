`timescale 1ns / 1ps
//==========================================================
// Window_Gen — 3×3 윈도우 생성기 (rev3 DW, 노션 4-1 §3)
//
// 구조: 31단(= 2행 + 3) 일렬 지연선 + 좌표 기반 경계 마스킹.
//   "라인버퍼 2줄 + 3탭 시프트"를 평탄화한 형태 — 픽셀이 1개/클럭
//   들어오면 3×3 이웃 9탭이 전부 준비된다 (픽셀당 재사용 최대 9회,
//   메모리 읽기는 픽셀당 정확히 1회).
//
// 탭 ↔ 지연 매핑 (d[0] = 가장 최근 등록된 픽셀):
//   pixel1(a)=d[30]  pixel2(b)=d[29]  pixel3(c)=d[28]   ← 윗행   (r-1)
//   pixel4(d)=d[16]  pixel5(e)=d[15]  pixel6(f)=d[14]   ← 가운데 (r)
//   pixel7(g)=d[ 2]  pixel8(h)=d[ 1]  pixel9(i)=d[ 0]   ← 아랫행 (r+1, 최신)
//   (같은 행 안에서 오른쪽이 더 최신 / 14클럭 전 = 한 행 위)
//
// 패딩 = 저장이 아니라 마스킹:
//   win_row/win_col(지금 탭이 나타내는 출력 윈도우 좌표, 0~13)이
//   경계값이면 경계 밖을 가리키는 탭을 0으로 덮는다.
//   진리표 = Docs/rev3(depthwise_conv)/Depthwise연산.xlsx 196행
//   (단위 TB는 이 표와 196클럭 전수 비교).
//
// FSM 계약 (Ctrl_FSM_DW가 지켜야 할 것):
//   1) din_valid = 체인 전진 게이트. PREFILL(16클럭) + CALC 구간 동안
//      연속 1 유지. 지연량이 곧 "행"의 의미라서, 새 픽셀 없는 클럭에
//      체인이 밀리면 정렬이 깨진다.
//   2) ⚠ 더미 시프트 15클럭: 마지막 15윈도우(아랫행 뒷부분)는 실픽셀
//      196개를 다 읽은 뒤에도 체인이 계속 전진해야 나온다. din_valid는
//      그대로 1 유지, 읽기 주소만 196에서 멈추면 됨 — 더미 값이 닿는
//      탭은 전부 마스킹 자리라 값은 don't care.
//   3) win_row/win_col 정렬(등록 1클럭 파이프 포함)은 통합 TB에서
//      상수로 확정한다 — MUL_LAT 오프셋 계약과 같은 방식.
//==========================================================
module Window_Gen #(
    parameter DATA_W = 16,
    parameter IMG_W  = 14       // 행 폭 (14×14 채널)
)(
    // ------- input -------
    clk,
    rst,

    din_valid,      // 새 픽셀 등록 펄스 (헤더의 FSM 계약 참조)
    din,            // 입력 픽셀 (UQ3.13)

    win_row,        // 지금 탭 출력이 나타내는 윈도우 좌표 (FSM 카운터)
    win_col,

    // ------- output -------
    pixel1,         // a (좌상)          pixel1 pixel2 pixel3
    pixel2,         // b                 pixel4 pixel5 pixel6
    pixel3,         // c                 pixel7 pixel8 pixel9
    pixel4,         // d
    pixel5,         // e (중앙)
    pixel6,         // f
    pixel7,         // g
    pixel8,         // h
    pixel9          // i (우하, 최신)
);
    // ==========================================================
    // ------- input -------
    input                   clk;
    input                   rst;

    input                   din_valid;
    input   [DATA_W-1:0]    din;

    input   [3:0]           win_row;
    input   [3:0]           win_col;

    // ------- output -------
    output  [DATA_W-1:0]    pixel1;
    output  [DATA_W-1:0]    pixel2;
    output  [DATA_W-1:0]    pixel3;
    output  [DATA_W-1:0]    pixel4;
    output  [DATA_W-1:0]    pixel5;
    output  [DATA_W-1:0]    pixel6;
    output  [DATA_W-1:0]    pixel7;
    output  [DATA_W-1:0]    pixel8;
    output  [DATA_W-1:0]    pixel9;

    // ==========================================================
    // 지연선 — 깊이 31 (= 2×IMG_W + 3). din_valid일 때만 한 칸 전진.

    localparam DEPTH = 2*IMG_W + 3;

    reg     [DATA_W-1:0]    buffer [0:DEPTH-1];     // 16비트짜리 31개

    integer k;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (k = 0; k < DEPTH; k = k + 1)
                buffer[k] <= {DATA_W{1'b0}};        // 전체 배열 0으로 초기화
        end
        else if (din_valid) begin
            buffer[0] <= din;
            for (k = 1; k < DEPTH; k = k + 1)
                buffer[k] <= buffer[k-1];           // 31단 지연 버퍼
        end
    end

    // ==========================================================
    // 경계 플래그 — 좌표는 FSM이 판단(카운터), 여기는 마스킹(데이터패스)만

    wire top    = (win_row == 4'd0);
    wire bottom = (win_row == IMG_W-1);
    wire left   = (win_col == 4'd0);
    wire right  = (win_col == IMG_W-1);

    // ==========================================================
    // 탭 + 마스킹 — 경계 밖을 가리키는 탭은 0 (엑셀 진리표와 일치해야 함)
    //   a: top|left    b: top       c: top|right
    //   d: left        e: 항상 실값   f: right
    //   g: bottom|left h: bottom    i: bottom|right

    assign pixel1 = (top    || left ) ? {DATA_W{1'b0}} : buffer[2*IMG_W+2];  // a
    assign pixel2 = (top            ) ? {DATA_W{1'b0}} : buffer[2*IMG_W+1];  // b
    assign pixel3 = (top    || right) ? {DATA_W{1'b0}} : buffer[2*IMG_W  ];  // c
    assign pixel4 = (          left ) ? {DATA_W{1'b0}} : buffer[IMG_W+2  ];  // d
    assign pixel5 =                                      buffer[IMG_W+1  ];  // e
    assign pixel6 = (          right) ? {DATA_W{1'b0}} : buffer[IMG_W    ];  // f
    assign pixel7 = (bottom || left ) ? {DATA_W{1'b0}} : buffer[2        ];  // g
    assign pixel8 = (bottom         ) ? {DATA_W{1'b0}} : buffer[1        ];  // h
    assign pixel9 = (bottom || right) ? {DATA_W{1'b0}} : buffer[0        ];  // i

endmodule
