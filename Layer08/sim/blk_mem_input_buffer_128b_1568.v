`timescale 1ns / 1ps
// 시뮬레이션 전용 스텁 — Vivado BMG 대체 (Vivado 프로젝트에 추가 금지!)
//   A 메모리: 입력 활성 버퍼, Simple Dual Port, 128b × 1,568
//   읽기 지연 1클럭 (Primitives Output Register OFF 전제 — 설계 기준)
//   초기화: INIT_FILE ≠ "" 이면 $readmemh (make_input_coe가 만든 .hex와 동일 포맷)
module blk_mem_input_buffer_128b_1568 #(
    parameter INIT_FILE = "../Data/Input_Data/layer07_input_q312_128x1568.hex"  // Layer08/ 에서 실행 기준
)(
    // Port A (Write)
    input                clka,
    input                ena,
    input                wea,
    input      [10:0]    addra,
    input      [127:0]   dina,

    // Port B (Read)
    input                clkb,
    input                enb,
    input      [10:0]    addrb,
    output reg [127:0]   doutb
);
    reg [127:0] mem [0:1567];
    integer i;

    initial begin
        for (i = 0; i < 1568; i = i + 1) mem[i] = 128'd0;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end

    always @(posedge clka) if (ena && wea) mem[addra] <= dina;
    always @(posedge clkb) if (enb)        doutb <= mem[addrb];   // latency 1

endmodule
