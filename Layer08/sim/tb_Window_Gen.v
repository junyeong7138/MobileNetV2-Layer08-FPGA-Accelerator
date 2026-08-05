`timescale 1ns / 1ps
//==========================================================
// tb_Window_Gen — Window_Gen 단위 전수 검증 (rev3 DW)
//
// 골든: sim/wg_golden.memh (Depthwise연산.xlsx 196행 × 9탭,
//       독립 파이썬 모델과 교차 검증 완료 — 불일치 0)
//
// 원리: 입력 픽셀 값 = 픽셀 번호(1~196)로 주입하면,
//       탭 출력이 곧 "이 탭이 가리키는 픽셀 번호"가 되어
//       엑셀 표와 직접 비교 가능. 패딩 자리는 0이어야 한다.
//       더미 시프트 15클럭은 16'hDEAD 주입 — 마스킹이 뚫리면 즉시 검출.
//
// 검사 정렬: 등록 N개 완료 시점(N = din_valid 累적)에
//       윈도우 w = N-16 (0~195)의 탭이 조합 출력에 나타난다.
//       (PREFILL 16 + 윈도우당 1등록, 마지막 15개는 더미 등록)
//
// 실행 (Layer08/ 디렉터리에서):
//   iverilog -o /tmp/sim_wg -s tb_Window_Gen \
//       sim/tb_Window_Gen.v rtl/rev3/Depthwise_Conv/Window_Gen.v
//   vvp /tmp/sim_wg
//==========================================================
module tb_Window_Gen;

    reg             clk, rst;
    reg             din_valid;
    reg  [15:0]     din;
    reg  [3:0]      win_row, win_col;

    wire [15:0]     p1, p2, p3, p4, p5, p6, p7, p8, p9;

    Window_Gen #(
        .DATA_W (16),
        .IMG_W  (14)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .din_valid  (din_valid),
        .din        (din),
        .win_row    (win_row),
        .win_col    (win_col),
        .pixel1     (p1), .pixel2 (p2), .pixel3 (p3),
        .pixel4     (p4), .pixel5 (p5), .pixel6 (p6),
        .pixel7     (p7), .pixel8 (p8), .pixel9 (p9)
    );

    //--------------------------------------------------
    always #5 clk = ~clk;   // 100 MHz

    reg [15:0] golden [0:1763];     // 196윈도우 × 9탭 (a~i 순)

    integer k, w, errors, checks;

    task check_tap;
        input integer win;
        input integer tap;          // 0=a … 8=i
        input [15:0]  got;
        begin
            checks = checks + 1;
            if (golden[win*9 + tap] !== got) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL win %0d (r%0d,c%0d) tap %0d : got %0d, expected %0d",
                             win, win/14, win%14, tap, got, golden[win*9 + tap]);
            end
        end
    endtask

    //--------------------------------------------------
    initial begin
        $readmemh("sim/wg_golden.memh", golden);

        clk = 0; rst = 1; din_valid = 0; din = 0;
        win_row = 0; win_col = 0;
        errors = 0; checks = 0;

        repeat (3) @(negedge clk);
        rst = 0;

        // k = 지금까지 완료된 등록 수. 이 negedge에서
        //  (a) 등록 k개 상태의 탭 검사 (w = k-16)
        //  (b) 다음 posedge에 등록될 픽셀 k+1 인가 (실픽셀 196 + 더미 15)
        for (k = 0; k <= 211; k = k + 1) begin
            @(negedge clk);

            if (k >= 16) begin
                w = k - 16;
                win_row = w / 14;
                win_col = w % 14;
                #1;     // 마스킹 조합 전파
                check_tap(w, 0, p1);  check_tap(w, 1, p2);  check_tap(w, 2, p3);
                check_tap(w, 3, p4);  check_tap(w, 4, p5);  check_tap(w, 5, p6);
                check_tap(w, 6, p7);  check_tap(w, 7, p8);  check_tap(w, 8, p9);
            end

            if (k < 211) begin
                din_valid = 1;
                din = (k + 1 <= 196) ? k[15:0] + 16'd1 : 16'hDEAD;  // 더미=DEAD (누출 검출용)
            end
            else begin
                din_valid = 0;
            end
        end

        //--------------------------------------------------
        if (checks != 196*9)
            $display("FAIL: 검사 수 %0d (기대 %0d)", checks, 196*9);
        else if (errors == 0)
            $display("PASS: 196윈도우 × 9탭 = %0d개 전수 일치 (더미 누출 없음)", checks);
        else
            $display("FAIL: %0d개 중 %0d개 불일치", checks, errors);

        $finish;
    end

endmodule
