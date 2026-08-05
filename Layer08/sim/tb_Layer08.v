`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/02 14:17:46
// Design Name: 
// Module Name: tb_Layer08
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
// tb_Layer08 — 통합 스모크: 실데이터(hex)로 메모리→주소→skew→SA 경로 검증
//
// 검증 내용
//   1. start 펄스 → PW1 전체 384타일(8×48) 완주 후 pw_done 1회
//   2. 첫 타일(filter_tile 0, ch_tile 0)의 psum 1,568개(196위치×8열) 전수 비교:
//      기대값 = A/B hex에서 직접 계산한 8채널 부분 내적
//      → COE 패킹·주소 생성·역순 shift-in·skew·MUL_LAT/MEM_LAT 오프셋 검증
//   3. ★ 최종 출력 75,264개(384ch×196위치) 전수 비트 일치:
//      ★제출판(과제=pointwise conv까지): out_data = 32b 누산값(8타일 누산 완료)
//      기대값 = 64채널 전체 내적 Σ_{ic=0..63} x[ic][pos] × w[filter][ic] (hex에서 계산)
//      (Post_Proc 복원 시에는 fixp_stage1_uq313.hex와 16b 비교로 되돌릴 것)
//
// 실행 (Layer08/ 폴더에서 — hex 상대경로 기준):
//   iverilog -o /tmp/sim_l8 -s tb_Layer08 sim/tb_Layer08.v sim/mult_gen_0.v \
//     sim/blk_mem_input_buffer_128b_1568.v sim/blk_mem_weight_buffer_128b_3072.v \
//     rtl/Layer08.v rtl/Pointwise_Conv/PointWise_Conv.v rtl/Pointwise_Conv/Ctrl_FSM.v \
//     rtl/Pointwise_Conv/Skew_Regs.v rtl/Pointwise_Conv/SystolicArray.v \
//     rtl/Pointwise_Conv/ProcessingElement.v rtl/Pointwise_Conv/Accum_Buffer.v \
//     && vvp /tmp/sim_l8
//
// ★ 합성 후 시뮬(Vivado post-synth functional): `POST_SYNTH` define 필수.
//   넷리스트에서는 내부 신호명이 사라져 계층 참조가 성립하지 않으므로,
//   POST_SYNTH 모드는 첫 타일 psum 채점기(계층 참조)만 제외한다.
//   최종 출력 75,264개 채점은 톱 포트(out_valid/out_data/out_pos)만 쓰므로
//   behavioral/post-synth 양쪽에서 동일하게 전수 비트 일치를 확인한다.
//   Vivado: Settings → Simulation → Compilation 탭 →
//           xsim.compile.xvlog.more_options 에 -d POST_SYNTH
//   (behavioral 전수 채점을 돌릴 때는 다시 지울 것)
//==========================================================

module tb_Layer08;
    localparam PE_ROW   = 8;
    localparam PE_COL   = 8;
    localparam LAYER_HW = 196;
    localparam MUL_LAT  = 4;
    localparam MEM_LAT  = 1;
    localparam OFFSET   = PE_ROW + MUL_LAT + MEM_LAT;   // valid 윈도우 시작 오프셋 (13)

    reg          clk, rst, start;
    wire         done;
    wire [PE_COL-1:0]     out_valid;
    wire [PE_COL*32-1:0]  out_data;
    wire [PE_COL*16-1:0]  out_pos;

    integer errors, n_checked, n_done, n_out;
    integer j, p, i, k, ch;

    Layer08 dut (
        .clk        (clk),
        .rst        (rst),
        .start      (start),
        .din        (16'd0),
        .addr       (16'd0),
        .done       (done),
        .out_valid  (out_valid),
        .out_data   (out_data),
        .out_pos    (out_pos)
    );

    always #5 clk = ~clk;

    //--------------------------------------------------
    // 레퍼런스: RTL과 같은 hex를 TB도 직접 읽어 첫 타일 기대값 계산
    //--------------------------------------------------
    reg [127:0] amem [0:1567];
    reg [127:0] bmem [0:3071];
    integer x_ref [0:PE_ROW-1][0:LAYER_HW-1];   // 채널 i, 위치 p (Q3.12 코드)
    integer w_ref [0:PE_ROW-1][0:PE_COL-1];     // 행(채널) i, 열(필터) j (2^-16 코드)
    integer ref_psum;

    // 전체 conv 레퍼런스 (64채널 내적용) — ★제출판 최종 채점 기준
    integer x_full [0:63][0:LAYER_HW-1];    // 전체 입력: 채널 ic, 위치 p
    integer w_full [0:383][0:63];           // 전체 가중치: 필터 f, 채널 ic

    // // 고정소수점 C 모델의 stage1 골든 (UQ3.13) — Post_Proc 복원 시 사용
    // reg [15:0] golden1 [0:384*LAYER_HW-1];

    integer f, ct, ic;

    initial begin
`ifdef XILINX_SIMULATOR
        // Vivado xsim (Windows): C:\ETRI_junyeong\MobileNetV2\data\ 에 hex 2개를 복사해 둘 것
        $readmemh("C:/ETRI_junyeong/MobileNetV2/data/layer07_input_q312_128x1568.hex", amem);
        $readmemh("C:/ETRI_junyeong/MobileNetV2/data/layer08_expand_w_q16_128x3072.hex", bmem);
`else
        // iverilog (Mac): Layer08/ 폴더에서 실행 기준 상대경로
        $readmemh("../Data/Input_Data/layer07_input_q312_128x1568.hex", amem);
        $readmemh("../Data/Weight/layer08_expand_w_q16_128x3072.hex",   bmem);
`endif
        // $readmemh("model/golden/fixp_stage1_uq313.hex",              golden1);
        // A: addr = pos (ch_tile 0), 슬라이스 i = 채널 i (첫 타일용)
        for (p = 0; p < LAYER_HW; p = p + 1)
            for (i = 0; i < PE_ROW; i = i + 1)
                x_ref[i][p] = $signed(amem[p][i*16 +: 16]);
        // B: addr = k, k번째 워드 = 행 (7-k)  → 행 i는 addr (7-i) (첫 타일용)
        for (i = 0; i < PE_ROW; i = i + 1)
            for (j = 0; j < PE_COL; j = j + 1)
                w_ref[i][j] = $signed(bmem[PE_ROW-1-i][j*16 +: 16]);
        // 전체 채널: A는 addr = ct*196+p, B는 addr = (ft*8+ct)*8+(7-i)
        for (ic = 0; ic < 64; ic = ic + 1)
            for (p = 0; p < LAYER_HW; p = p + 1)
                x_full[ic][p] = $signed(amem[(ic/8)*LAYER_HW + p][(ic%8)*16 +: 16]);
        for (f = 0; f < 384; f = f + 1)
            for (ic = 0; ic < 64; ic = ic + 1)
                w_full[f][ic] = $signed(bmem[((f/8)*8 + ic/8)*8 + (7 - ic%8)][(f%8)*16 +: 16]);
    end

    //--------------------------------------------------
    // done 펄스 카운트 — 포트만 사용 (behavioral/post-synth 공통)
    //--------------------------------------------------
    always @(negedge clk)
        if (!rst && done) n_done = n_done + 1;

`ifndef POST_SYNTH
    //--------------------------------------------------
    // 첫 타일 psum 채점기 — Ctrl_FSM valid/카운터를 계층 참조로 사용
    //   (RTL 전용: 합성 넷리스트에서는 내부 신호명이 사라지므로
    //    post-synth 시뮬에서는 POST_SYNTH define으로 통째로 제외)
    //--------------------------------------------------
    always @(negedge clk) begin
        if (!rst && dut.u_Pointwise_Conv.filter_tile_cnt == 0
                 && dut.u_Pointwise_Conv.ch_tile_cnt == 0) begin
            for (j = 0; j < PE_COL; j = j + 1) begin
                if (dut.u_Pointwise_Conv.valid[j]) begin
                    p = dut.u_Pointwise_Conv.calc_cyc_cnt - OFFSET - j;
                    if (p < 0 || p >= LAYER_HW) begin
                        errors = errors + 1;
                        $display("FAIL: valid[%0d]=1인데 p=%0d 범위 밖 (cnt=%0d)",
                                 j, p, dut.u_Pointwise_Conv.calc_cyc_cnt);
                    end
                    else begin
                        ref_psum = 0;
                        for (i = 0; i < PE_ROW; i = i + 1)
                            ref_psum = ref_psum + x_ref[i][p]*w_ref[i][j];
                        if ($signed(dut.u_Pointwise_Conv.psum_out[j*32 +: 32]) !== ref_psum) begin
                            errors = errors + 1;
                            if (errors < 10)
                                $display("FAIL pos %0d col %0d : got %0d, expected %0d",
                                         p, j, $signed(dut.u_Pointwise_Conv.psum_out[j*32 +: 32]), ref_psum);
                        end
                        n_checked = n_checked + 1;
                    end
                end
            end
        end
    end

`endif  // !POST_SYNTH

    //--------------------------------------------------
    // 최종 출력 채점기 — ★제출판: 32b 누산값 vs 64채널 전체 내적 (비트 일치)
    //   톱 포트만 사용 → behavioral/post-synth 양쪽에서 동일 전수 채점.
    //   채널 복원: 배출 순서가 결정적이므로 레인 j의 n번째 유효 출력의
    //   filter_tile = n/LAYER_HW  →  ch = filter_tile*8 + j  (계층 참조 불필요)
    //--------------------------------------------------
    integer ref_full;
    integer lane_cnt [0:PE_COL-1];

    always @(negedge clk) begin
        if (!rst) begin
            for (j = 0; j < PE_COL; j = j + 1) begin
                if (out_valid[j]) begin
                    ch = (lane_cnt[j]/LAYER_HW)*PE_COL + j;
                    p  = out_pos[j*16 +: 16];
                    ref_full = 0;
                    for (ic = 0; ic < 64; ic = ic + 1)
                        ref_full = ref_full + x_full[ic][p]*w_full[ch][ic];
                    if ($signed(out_data[j*32 +: 32]) !== ref_full) begin
                        errors = errors + 1;
                        if (errors < 10)
                            $display("FAIL out ch %0d pos %0d : got %0d, expected %0d",
                                     ch, p, $signed(out_data[j*32 +: 32]), ref_full);
                    end
                    lane_cnt[j] = lane_cnt[j] + 1;
                    n_out = n_out + 1;
                end
            end
        end
    end

    //--------------------------------------------------
    initial begin
        clk = 0; rst = 1; start = 0;
        errors = 0; n_checked = 0; n_done = 0; n_out = 0;
        for (j = 0; j < PE_COL; j = j + 1) lane_cnt[j] = 0;

        // post-synth 시뮬에서는 glbl의 GSR이 시작 후 100ns 동안 전체 FF를 잡고
        // 있으므로, 그 창 안에서 쏜 start는 씹힌다 → 120ns까지 리셋 유지 후 시작
        // (behavioral에서도 무해 — 전체 시각만 100ns 뒤로 밀림)
        repeat (12) @(negedge clk);
        rst = 0;

        @(negedge clk);
        start = 1; @(negedge clk);
        start = 0;

        // PW1 전체: 384타일 × (LOAD 8 + CALC/DRAIN ~219) ≈ 8.8만 클럭
        k = 0;
        while (n_done == 0 && k < 200000) begin
            @(negedge clk);
            k = k + 1;
        end

        if (n_done == 0) begin
            errors = errors + 1;
            $display("FAIL: timeout — pw_done이 안 옴 (%0d클럭)", k);
        end
        if (n_out !== 384*LAYER_HW) begin
            errors = errors + 1;
            $display("FAIL: 최종 출력 채점 수 %0d (기대 %0d)", n_out, 384*LAYER_HW);
        end
`ifndef POST_SYNTH
        if (n_checked !== PE_COL*LAYER_HW) begin
            errors = errors + 1;
            $display("FAIL: 첫 타일 채점 수 %0d (기대 %0d)", n_checked, PE_COL*LAYER_HW);
        end

        if (errors == 0)
            $display("=== PASS: Layer08 PW conv(제출판) — 첫 타일 psum %0d개 + 최종 32b 누산값 %0d개 비트 일치, pw_done @%0d클럭 ===",
                     n_checked, n_out, k);
        else
            $display("=== FAIL: %0d error(s) ===", errors);
`else
        // post-synth: 첫 타일 psum 채점(계층 참조)만 제외하고, 최종 출력 75,264개는
        // 톱 포트에서 behavioral과 동일하게 전수 비트 일치 채점된다.
        if (n_done !== 1) begin
            errors = errors + 1;
            $display("FAIL: done 펄스 %0d회 (기대 1회)", n_done);
        end
        if (errors == 0)
            $display("=== PASS(post-synth): 넷리스트 포트 기준 최종 32b 누산값 %0d개 비트 일치, pw_done @%0d클럭 ===",
                     n_out, k);
        else
            $display("=== FAIL(post-synth): %0d error(s) ===", errors);
`endif
        $finish;
    end

endmodule
