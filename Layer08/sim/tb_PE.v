//==========================================================
// tb_PE — WS ProcessingElement 단독 검증 (곱셈기 IP 4클럭 파이프라인 반영)
//
// PE 2개를 세로(열 방향)로 체인:
//   - w  : w_top → PE0.w_reg → PE1.w_reg  (shift-in, 역순 공급 확인)
//   - psum: 0 → PE0 → PE1                 (부분합 누산)
//   - x  : 행별 독립 입력, 행1은 1클럭 skew (곱셈기 지연은 행끼리 상쇄!)
//
// 타이밍: x 투입 → psum_out 반영까지 MUL_LAT(4) + 1 = 5클럭
//         (곱셈 파이프 4 + psum 레지스터 1)
//
// 검증 항목
//   1. shift-in 2클럭 후 w_reg 배치: 먼저 넣은 값이 아래(PE1)로 밀림
//   2. CALC 중 psum_out(PE1) = x0*w0 + x1*w1 (열 내적, 음수 포함, +4클럭 지연)
//   3. x_out 1클럭 지연 전달 (곱셈기와 무관)
//   4. CALC 중 가중치 고정 확인
//
// 실행:
//   iverilog -o /tmp/sim_pe -s tb_PE sim/tb_PE.v sim/mult_gen_0.v rtl/Pointwise_Conv/ProcessingElement.v && vvp /tmp/sim_pe
//==========================================================
`timescale 1ns/1ps

module tb_PE;
    parameter DATA_W  = 16;
    parameter ACC_W   = 32;
    parameter MUL_LAT = 4;      // mult_gen_0 Pipeline Stages

    reg                      clk, rst, en, load_mode;
    reg  signed [DATA_W-1:0] x0_in, x1_in;   // 행0 / 행1 입력 (행1은 skew 1클럭)
    reg  signed [DATA_W-1:0] w_top;          // 열 위쪽에서 밀어 넣는 가중치
    wire signed [DATA_W-1:0] x0_out, x1_out;
    wire signed [DATA_W-1:0] w_01, w_bot;    // PE0→PE1 체인 / PE1 아래 (관찰용)
    wire signed [ACC_W-1:0]  psum_0, psum_1; // PE0→PE1 체인 / 열 최종 출력

    integer errors;

    // PE0 (행 0, 열 맨 위) — psum_in은 0 고정
    ProcessingElement #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_pe0 (
        .clk        (clk),
        .rst        (rst),
        .en         (en),
        .load_mode  (load_mode),
        .x_in       (x0_in),
        .w_in       (w_top),
        .psum_in    ({ACC_W{1'b0}}),
        .x_out      (x0_out),
        .w_out      (w_01),
        .psum_out   (psum_0)
    );

    // PE1 (행 1) — 가중치/부분합 모두 PE0에서 내려받음
    ProcessingElement #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_pe1 (
        .clk        (clk),
        .rst        (rst),
        .en         (en),
        .load_mode  (load_mode),
        .x_in       (x1_in),
        .w_in       (w_01),
        .psum_in    (psum_0),
        .x_out      (x1_out),
        .w_out      (w_bot),
        .psum_out   (psum_1)
    );

    always #5 clk = ~clk;

    task check32(input [127:0] name, input signed [ACC_W-1:0] got, input signed [ACC_W-1:0] exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s : got %0d, expected %0d (t=%0t)", name, got, exp, $time);
            end
        end
    endtask

    initial begin
        clk = 0; rst = 1; en = 0; load_mode = 0;
        x0_in = 0; x1_in = 0; w_top = 0; errors = 0;

        repeat (2) @(negedge clk);
        rst = 0;

        //--------------------------------------------------
        // 1) LOAD: shift-in 2클럭. 먼저 넣은 값이 끝(PE1)까지 밀린다
        //    → 아래 행(PE1)의 가중치 w1=-3을 먼저, 그다음 w0=2 (역순 공급)
        //    이 동안 x=0 → 곱셈 파이프는 0으로 채워짐 (결정적)
        //--------------------------------------------------
        load_mode = 1;
        w_top = -16'sd3;  @(negedge clk);   // 1클럭째: PE0 <= -3
        w_top =  16'sd2;  @(negedge clk);   // 2클럭째: PE0 <= 2, PE1 <= -3
        load_mode = 0;

        check32("w_reg0 (via w_01)",  w_01,  2);
        check32("w_reg1 (via w_bot)", w_bot, -3);

        //--------------------------------------------------
        // 2) CALC: x0 = {1,-2,5,0}, x1은 1클럭 늦게 {10,4,-1,7}
        //    기대 열 내적: 1*2+10*(-3) = -28
        //                 -2*2+ 4*(-3) = -16
        //                  5*2+(-1)*(-3) = 13
        //                  0*2+ 7*(-3) = -21
        //    psum_1 도착: 해당 x0 투입 + MUL_LAT(4) + 2클럭
        //--------------------------------------------------
        en = 1;
        x0_in = 16'sd1;   x1_in = 16'sd0;   @(negedge clk); // c0 투입
        x0_in = -16'sd2;  x1_in = 16'sd10;  @(negedge clk); // c1 투입
        check32("x0_out delay", x0_out, -2);                 // x 전달은 여전히 1클럭 (c1의 x0)
        x0_in = 16'sd5;   x1_in = 16'sd4;   @(negedge clk); // c2 투입
        x0_in = 16'sd0;   x1_in = -16'sd1;  @(negedge clk); // c3 투입
        x0_in = 16'sd0;   x1_in = 16'sd7;   @(negedge clk); // c4 투입
        check32("psum_0 (1*2, +4클럭)", psum_0, 2);          // c0 곱이 MUL_LAT+1클럭 뒤 도착
        x1_in = 16'sd0;                     @(negedge clk);
        check32("dot pos0", psum_1, -28);
        @(negedge clk);
        check32("dot pos1", psum_1, -16);
        @(negedge clk);
        check32("dot pos2", psum_1, 13);
        @(negedge clk);
        check32("dot pos3", psum_1, -21);

        //--------------------------------------------------
        // 3) CALC 중 가중치 고정 확인 (load_mode=0이면 w_top이 바뀌어도 유지)
        //--------------------------------------------------
        w_top = 16'sd99; @(negedge clk);
        check32("w_reg0 stationary", w_01, 2);
        check32("w_reg1 stationary", w_bot, -3);

        if (errors == 0) $display("=== PASS: WS PE (MUL_LAT=%0d) all checks OK ===", MUL_LAT);
        else             $display("=== FAIL: %0d error(s) ===", errors);
        $finish;
    end

endmodule
