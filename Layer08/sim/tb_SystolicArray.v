`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 13:53:12
// Design Name: 
// Module Name: tb_SystolicArray
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
// tb_SystolicArray — 8x8 WS 배열 단독 검증 (스펙 구현 가이드 2번)
//
// 시나리오 (skew_regs/ctrl_fsm이 아직 없으므로 TB가 그 역할을 대신함)
//   1. LOAD : 8클럭 shift-in — 행 7의 가중치부터 역순 공급
//   2. CALC : N개 위치의 입력 벡터(8ch)를 행 i마다 i클럭 지연(skew)으로 공급
//   3. 검증 : 열 j, 위치 p의 결과는 posedge(p + ROW-1 + j + MUL_LAT) 직후 등장
//             (곱셈기 IP 4클럭 파이프라인 — 행끼리 상쇄되어 상수 오프셋만 발생.
//              Ctrl_FSM valid_j 윈도우와 동일한 타이밍)
//             기대값 = 소프트웨어 내적 ref[p][j] = Σ_i X[p][i]*W[i][j]
//
// 실행:
//   iverilog -o /tmp/sim_sa -s tb_SystolicArray sim/tb_SystolicArray.v sim/mult_gen_0.v rtl/Pointwise_Conv/SystolicArray.v rtl/Pointwise_Conv/ProcessingElement.v && vvp /tmp/sim_sa
//==========================================================
`timescale 1ns/1ps

module tb_SystolicArray;
    parameter DATA_W = 16;
    parameter ACC_W  = 32;
    parameter ROW    = 8;
    parameter COL    = 8;
    parameter N_POS  = 10;   // 테스트할 입력 위치(픽셀) 수
    parameter MUL_LAT = 4;   // 곱셈기 IP 파이프라인 지연

    reg                      clk, rst, en, load_mode;
    reg  [ROW*DATA_W-1:0]    x_in;
    reg  [COL*DATA_W-1:0]    w_in;
    wire [COL*ACC_W-1:0]     psum_out;

    integer errors;
    integer c, r, jj, p, k;

    // 테스트 데이터 (결정적 패턴, 음수 포함)
    integer X   [0:N_POS-1][0:ROW-1];   // 입력: 위치 p, 채널 i
    integer W   [0:ROW-1][0:COL-1];     // 가중치: 입력채널 i, 필터 j
    integer ref_out [0:N_POS-1][0:COL-1];

    SystolicArray #(
        .DATA_W             (DATA_W),
        .ACC_W              (ACC_W),
        .PE_ROW             (ROW),
        .PE_COL             (COL)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .en         (en),
        .load_mode  (load_mode),
        .x_in       (x_in),
        .w_in       (w_in),
        .psum_out   (psum_out)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0; rst = 1; en = 0; load_mode = 0;
        x_in = 0; w_in = 0; errors = 0;

        // 데이터 생성 + 소프트웨어 기대값 (GEMM 레퍼런스)
        for (p = 0; p < N_POS; p = p + 1)
            for (r = 0; r < ROW; r = r + 1)
                X[p][r] = ((p*3 + r*5) % 17) - 8;            // -8 ~ +8
        for (r = 0; r < ROW; r = r + 1)
            for (jj = 0; jj < COL; jj = jj + 1)
                W[r][jj] = ((r*7 + jj*11) % 13) - 6;         // -6 ~ +6
        for (p = 0; p < N_POS; p = p + 1)
            for (jj = 0; jj < COL; jj = jj + 1) begin
                ref_out[p][jj] = 0;
                for (r = 0; r < ROW; r = r + 1)
                    ref_out[p][jj] = ref_out[p][jj] + X[p][r]*W[r][jj];
            end

        repeat (2) @(negedge clk);
        rst = 0;

        //--------------------------------------------------
        // 1) LOAD: 8클럭 shift-in, 행 7 가중치부터 (역순 공급)
        //--------------------------------------------------
        load_mode = 1;
        for (k = 0; k < ROW; k = k + 1) begin
            for (jj = 0; jj < COL; jj = jj + 1)
                w_in[jj*DATA_W +: DATA_W] = W[ROW-1-k][jj];   // 32b integer → 16b 절단
            @(negedge clk);
        end
        load_mode = 0;
        w_in = 0;

        // 가중치 배치 계층 참조로 확인 (ROWS[i].COLS[j] 라벨 경로)
        if ($signed(dut.ROWS[0].COLS[0].pe_inst.w_reg) !== W[0][0] ||
            $signed(dut.ROWS[7].COLS[7].pe_inst.w_reg) !== W[7][7] ||
            $signed(dut.ROWS[3].COLS[5].pe_inst.w_reg) !== W[3][5]) begin
            errors = errors + 1;
            $display("FAIL weight placement after shift-in");
        end

        //--------------------------------------------------
        // 2) CALC + 3) 열별 valid 윈도우에서 출력 비교
        //    행 i 입력은 i클럭 지연(skew): cycle c에 X[c-i][i] 공급
        //--------------------------------------------------
        en = 1;
        for (c = 0; c < N_POS + ROW + COL + MUL_LAT + 2; c = c + 1) begin
            for (r = 0; r < ROW; r = r + 1)
                if (c >= r && (c - r) < N_POS)
                    x_in[r*DATA_W +: DATA_W] = X[c-r][r];     // 32b integer → 16b 절단
                else
                    x_in[r*DATA_W +: DATA_W] = {DATA_W{1'b0}};

            @(posedge clk);
            #1;  // 레지스터 출력 안정화 후 샘플

            // posedge(c) 직후: 열 j에는 위치 p = c-(ROW-1)-j-MUL_LAT 의 결과가 떠 있음
            for (jj = 0; jj < COL; jj = jj + 1) begin
                p = c - (ROW-1) - jj - MUL_LAT;
                if (p >= 0 && p < N_POS) begin
                    if ($signed(psum_out[jj*ACC_W +: ACC_W]) !== ref_out[p][jj]) begin
                        errors = errors + 1;
                        $display("FAIL pos %0d col %0d : got %0d, expected %0d (c=%0d)",
                                 p, jj, $signed(psum_out[jj*ACC_W +: ACC_W]), ref_out[p][jj], c);
                    end
                end
            end
        end
        en = 0;

        if (errors == 0)
            $display("=== PASS: 8x8 WS SystolicArray, %0d position x %0d column all match ===", N_POS, COL);
        else
            $display("=== FAIL: %0d error(s) ===", errors);
        $finish;
    end

endmodule
