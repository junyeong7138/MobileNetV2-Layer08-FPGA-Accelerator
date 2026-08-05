`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 13:18:31
// Design Name: 
// Module Name: tb_Ctrl_FSM
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
// tb_Ctrl_FSM — pw_engine 제어 FSM 단독 검증
//
// 작은 구성(PE 2x2, 위치 4, 채널타일 2 × 필터타일 3 = 6타일)으로
// 전체 타일 루프를 돌리고 사이클 수를 채점:
//   - load_mode 총합 = 6타일 × PE_ROW(2)      = 12
//   - en        총합 = 6타일 × (4 + 2+2+4+2=10 → 14) = 84
//     (CALC+DRAIN, DRAIN에도 켜짐! DRAIN에 곱셈기 지연 MUL_LAT=4 포함)
//   - valid     총합 = 6타일 × PE_COL×LAYER_HW = 48
//   - done      = 정확히 1클럭 펄스 1회
//   - load_mode와 en이 동시에 1인 사이클 = 0
//   - done 후 start 재투입 → 두 번째 run도 동일하게 완주 (재트리거)
//
// 실행:
//   iverilog -o /tmp/sim_fsm -s tb_Ctrl_FSM sim/tb_Ctrl_FSM.v rtl/Pointwise_Conv/Ctrl_FSM.v && vvp /tmp/sim_fsm
//==========================================================
`timescale 1ns/1ps

module tb_Ctrl_FSM;
    parameter PE_ROW   = 2;
    parameter PE_COL   = 2;
    parameter LAYER_HW = 4;
    parameter N_CTILE  = 2;
    parameter N_FTILE  = 3;
    parameter MUL_LAT  = 4;     // 곱셈기 IP 파이프라인 지연
    parameter MEM_LAT  = 1;     // 버퍼 BRAM 읽기 지연

    localparam N_TILES   = N_CTILE * N_FTILE;
    localparam DRAIN_CYC = PE_ROW + PE_COL + MUL_LAT + MEM_LAT + 2;

    reg                 clk, rst, start;
    wire                load_mode, en, done;
    wire [PE_COL-1:0]   valid;
    wire [15:0]         load_cnt, calc_cyc_cnt, ch_tile_cnt, filter_tile_cnt;
    wire                first_ch_tile, last_ch_tile;

    integer cnt_load, cnt_en, cnt_valid, cnt_done, errors;
    integer k, run;
    reg     running;

    Ctrl_FSM #(
        .PE_ROW     (PE_ROW  ),
        .PE_COL     (PE_COL  ),
        .LAYER_HW   (LAYER_HW),
        .N_CTILE    (N_CTILE ),
        .N_FTILE    (N_FTILE ),
        .MUL_LAT    (MUL_LAT ),
        .MEM_LAT    (MEM_LAT )
    ) dut (
        .clk         (clk        ),
        .rst         (rst        ),
        .start       (start      ),
        .load_mode   (load_mode  ),
        .en          (en         ),
        .valid       (valid      ),
        .done        (done       ),
        .load_cnt    (load_cnt   ),
        .calc_cyc_cnt     (calc_cyc_cnt    ),
        .ch_tile_cnt      (ch_tile_cnt     ),
        .filter_tile_cnt      (filter_tile_cnt     ),
        .first_ch_tile (first_ch_tile),
        .last_ch_tile  (last_ch_tile )
    );

    always #5 clk = ~clk;

    // 사이클 채점기
    always @(negedge clk) begin
        if (running) begin
            cnt_load  = cnt_load  + load_mode;
            cnt_en    = cnt_en    + en;
            cnt_valid = cnt_valid + valid[0] + valid[1];
            cnt_done  = cnt_done  + done;
            if (load_mode && en) begin
                errors = errors + 1;
                $display("FAIL: load_mode/en 동시 assert (t=%0t)", $time);
            end
        end
    end

    task check(input [127:0] name, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("FAIL %0s : got %0d, expected %0d", name, got, exp);
            end
        end
    endtask

    initial begin
        clk = 0; rst = 1; start = 0; running = 0; errors = 0;

        repeat (2) @(negedge clk);
        rst = 0;

        // 같은 시나리오 2회 — 두 번째 run이 재트리거 검증
        for (run = 0; run < 2; run = run + 1) begin
            cnt_load = 0; cnt_en = 0; cnt_valid = 0; cnt_done = 0;

            @(negedge clk);
            running = 1;
            start   = 1;  @(negedge clk);
            start   = 0;

            k = 0;
            while (cnt_done == 0 && k < 500) begin
                @(negedge clk);
                k = k + 1;
            end
            repeat (3) @(negedge clk);      // done이 1클럭 만에 내려가는지 관찰 구간
            running = 0;

            if (k >= 500) begin
                errors = errors + 1;
                $display("FAIL: run %0d timeout — done이 안 옴", run);
            end
            check("load_mode cycles", cnt_load,  N_TILES * PE_ROW);
            check("en cycles",        cnt_en,    N_TILES * (LAYER_HW + DRAIN_CYC));
            check("valid cycles",     cnt_valid, N_TILES * PE_COL * LAYER_HW);
            check("done pulse",       cnt_done,  1);
        end

        if (errors == 0)
            $display("=== PASS: Ctrl_FSM %0d-tile loop x 2 runs OK ===", N_TILES);
        else
            $display("=== FAIL: %0d error(s) ===", errors);
        $finish;
    end

endmodule
