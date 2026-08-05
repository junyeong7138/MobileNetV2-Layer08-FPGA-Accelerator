`timescale 1ns / 1ps
// 시뮬레이션 전용 스텁 — Vivado BMG 대체 (Vivado 프로젝트에 추가 금지!)
//   B 메모리: 가중치 버퍼, Simple Dual Port, 128b × 3,072
//   읽기 지연 1클럭 (Primitives Output Register OFF 전제 — 설계 기준)
//   초기화: INIT_FILE ≠ "" 이면 $readmemh (make_weight_coe가 만든 .hex와 동일 포맷)
module blk_mem_weight_buffer_128b_3072 #(
    parameter INIT_FILE = "../Data/Weight/layer08_expand_w_q16_128x3072.hex"    // Layer08/ 에서 실행 기준
)(
    // Port A (Write)
    input                clka,
    input                ena,
    input                wea,
    input      [11:0]    addra,
    input      [127:0]   dina,

    // Port B (Read)
    input                clkb,
    input                enb,
    input      [11:0]    addrb,
    output reg [127:0]   doutb
);
    reg [127:0] mem [0:3071];
    integer i;

    initial begin
        for (i = 0; i < 3072; i = i + 1) mem[i] = 128'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clka) if (ena && wea) mem[addra] <= dina;
    always @(posedge clkb) if (enb)        doutb <= mem[addrb];   // latency 1

endmodule
