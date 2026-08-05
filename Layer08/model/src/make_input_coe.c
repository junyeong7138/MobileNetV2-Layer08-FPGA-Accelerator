//==========================================================
// make_input_coe.c — A 메모리(입력 활성 버퍼 128b×1,568)용 COE 생성
//
// 입력 : Data/Input_Data/mobilenetv2_result_layer07.bin (float32, 64ch×14×14, 채널-major)
// 변환 : Q3.12 양자화 (round-half-up — fixp_layer08.c와 동일 규칙!)
// 패킹 : 주소 addr = c_tile×196 + pos   (c_tile 0..7, pos 0..195 → 깊이 1,568)
//        워드 [16i+15 : 16i] = 채널 (c_tile×8 + i)  ← SA x_in의 행 i 슬라이스와 1:1
//        (hex 32자리에서 맨 앞 4자리 = 행7 채널, 맨 뒤 4자리 = 행0 채널)
// 출력 : Data/Input_Data/layer07_input_q312_128x1568.coe   (Vivado BMG용)
//        Data/Input_Data/layer07_input_q312_128x1568.hex   ($readmemh 시뮬용, 동일 내용)
//
// 빌드/실행 (이 폴더 model/ 에서):
//   gcc make_input_coe.c -o make_coe -lm && ./make_coe
//==========================================================
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>

#define IN_CH   64
#define HW      14
#define SP      (HW*HW)         // 196
#define PE_ROW  8
#define N_CTILE (IN_CH/PE_ROW)  // 8
#define DEPTH   (N_CTILE*SP)    // 1,568

#define F_IN    12              // Q3.12

#define INPUT_FILE "../../Data/Input_Data/mobilenetv2_result_layer07.bin"
#define COE_FILE   "../../Data/Input_Data/layer07_input_q312_128x1568.coe"
#define HEX_FILE   "../../Data/Input_Data/layer07_input_q312_128x1568.hex"

// fixp_layer08.c와 동일한 양자화 (round-half-up)
static int16_t quant_q312 (double v)
{
    double s = floor(v * (double)(1 << F_IN) + 0.5);
    if (s >  32767.0) return  32767;
    if (s < -32768.0) return -32768;
    return (int16_t)s;
}

int main (void)
{
    FILE *fin = fopen(INPUT_FILE, "rb");
    if (!fin) { printf("FAIL: %s 열기 실패 (model/ 에서 실행했는지 확인)\n", INPUT_FILE); return 1; }

    static float x_f[IN_CH*SP];
    if (fread(x_f, sizeof(float), IN_CH*SP, fin) != IN_CH*SP) { printf("FAIL: 입력 크기 이상\n"); return 1; }
    fclose(fin);

    static int16_t xq[IN_CH*SP];
    for (int i = 0; i < IN_CH*SP; i++)
        xq[i] = quant_q312(x_f[i]);

    FILE *fcoe = fopen(COE_FILE, "w");
    FILE *fhex = fopen(HEX_FILE, "w");
    if (!fcoe || !fhex) { printf("FAIL: 출력 파일 생성 실패\n"); return 1; }

    fprintf(fcoe, "; A 메모리 (입력 활성 버퍼) 128b x %d\n", DEPTH);
    fprintf(fcoe, "; layer07 출력 Q3.12, addr = c_tile*%d + pos, [16i+15:16i] = ch(c_tile*8+i)\n", SP);
    fprintf(fcoe, "memory_initialization_radix=16;\n");
    fprintf(fcoe, "memory_initialization_vector=\n");

    for (int addr = 0; addr < DEPTH; addr++) {
        int c_tile = addr / SP;
        int pos    = addr % SP;
        // 행 7(상위 hex) → 행 0(하위 hex) 순서로 출력
        for (int i = PE_ROW-1; i >= 0; i--) {
            uint16_t code = (uint16_t)xq[(c_tile*PE_ROW + i)*SP + pos];
            fprintf(fcoe, "%04x", code);
            fprintf(fhex, "%04x", code);
        }
        fprintf(fcoe, (addr == DEPTH-1) ? ";\n" : ",\n");
        fprintf(fhex, "\n");
    }
    fclose(fcoe);
    fclose(fhex);

    // 검증용 미리보기: addr 0 (c_tile0, pos0) = 채널 7..0의 pos(0,0)
    printf("=== %s (%d words) ===\n", COE_FILE, DEPTH);
    printf("addr 0 미리보기 (float → Q3.12 코드):\n");
    for (int i = PE_ROW-1; i >= 0; i--)
        printf("  ch%d: %+.6f -> %6d (0x%04x)\n",
               i, x_f[i*SP], xq[i*SP], (uint16_t)xq[i*SP]);
    printf("PASS\n");
    return 0;
}
