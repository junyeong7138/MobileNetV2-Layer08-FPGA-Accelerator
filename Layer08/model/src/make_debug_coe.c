//==========================================================
// make_debug_coe.c — 파형 눈검사용 디버그 데이터셋 (A/B 메모리 대체본)
//
// 실데이터의 복잡한 소수 대신 암산 가능한 값으로 채운다:
//   입력   x[ic][p] = 1.0 + 0.5×(p%4)          → 1.0 / 1.5 / 2.0 / 2.5
//   가중치 w[f][ic] = +0.03125 (f 짝수)          (2^-16 코드 +2048)
//                     -0.03125 (f 홀수)          (          -2048)
//
// 기대 출력 (64채널 내적): Σw = ±2.0 이므로
//   out[f][p] = ±2.0 × x = ±(2.0 / 3.0 / 4.0 / 5.0)   ← p%4에 따라
//   채널 타일당 누산 증가분 = out/8 = ±(0.25 / 0.375 / 0.5 / 0.625)
//   → BANK[j].acc_new(Fixed Point 28)이 8단계로 균등하게 자라는 게 보임
//
// 패킹 규칙은 실데이터 생성기(make_input_coe/make_weight_coe)와 완전 동일.
// 출력: Data/Debug/ 아래 coe/hex 4개 (파일명은 실데이터와 동일 — 교체 사용)
//
// 빌드/실행 (이 폴더 model/ 에서):
//   gcc make_debug_coe.c -o make_dbg -lm && ./make_dbg
//==========================================================
#include <stdio.h>
#include <stdint.h>

#define IN_CH   64
#define EXP_CH  384
#define HW      14
#define SP      (HW*HW)
#define PE_ROW  8
#define PE_COL  8
#define N_CTILE (IN_CH/PE_ROW)      // 8
#define N_FTILE (EXP_CH/PE_COL)     // 48
#define DEPTH_A (N_CTILE*SP)        // 1,568
#define DEPTH_B (N_FTILE*N_CTILE*PE_ROW)    // 3,072

// Q3.12 코드: 1.0=0x1000, 0.5=0x0800 → x = 0x1000 + (p%4)*0x0800
static int16_t x_code (int p)   { return (int16_t)(4096 + (p % 4) * 2048); }
// 2^-16 코드: 0.03125 = 2048
static int16_t w_code (int f)   { return (f % 2 == 0) ? (int16_t)2048 : (int16_t)-2048; }

int main (void)
{
    FILE *fc, *fh;

    // ---- A 메모리 (입력) ----
    fc = fopen("../../Data/Debug/layer07_input_q312_128x1568.coe", "w");
    fh = fopen("../../Data/Debug/layer07_input_q312_128x1568.hex", "w");
    if (!fc || !fh) { printf("FAIL: Data/Debug 폴더 확인\n"); return 1; }
    fprintf(fc, "; 디버그 입력: 모든 채널 x = 1.0/1.5/2.0/2.5 (p%%4)\n");
    fprintf(fc, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
    for (int addr = 0; addr < DEPTH_A; addr++) {
        int pos = addr % SP;
        for (int i = PE_ROW-1; i >= 0; i--) {           // 채널은 전부 동일 값
            fprintf(fc, "%04x", (uint16_t)x_code(pos));
            fprintf(fh, "%04x", (uint16_t)x_code(pos));
        }
        fprintf(fc, (addr == DEPTH_A-1) ? ";\n" : ",\n");
        fprintf(fh, "\n");
    }
    fclose(fc); fclose(fh);

    // ---- B 메모리 (가중치) ----
    fc = fopen("../../Data/Debug/layer08_expand_w_q16_128x3072.coe", "w");
    fh = fopen("../../Data/Debug/layer08_expand_w_q16_128x3072.hex", "w");
    if (!fc || !fh) { printf("FAIL: Data/Debug 폴더 확인\n"); return 1; }
    fprintf(fc, "; 디버그 가중치: 짝수 필터 +0.03125, 홀수 필터 -0.03125 (전 채널 동일)\n");
    fprintf(fc, "memory_initialization_radix=16;\nmemory_initialization_vector=\n");
    for (int addr = 0; addr < DEPTH_B; addr++) {
        int f_tile = addr / (N_CTILE*PE_ROW);
        for (int j = PE_COL-1; j >= 0; j--) {           // 채널(행)과 무관, 필터 부호만
            fprintf(fc, "%04x", (uint16_t)w_code(f_tile*PE_COL + j));
            fprintf(fh, "%04x", (uint16_t)w_code(f_tile*PE_COL + j));
        }
        fprintf(fc, (addr == DEPTH_B-1) ? ";\n" : ",\n");
        fprintf(fh, "\n");
    }
    fclose(fc); fclose(fh);

    printf("=== 디버그 데이터셋 생성 완료 (Data/Debug/) ===\n");
    printf("기대 출력: 짝수 필터 +2.0/+3.0/+4.0/+5.0, 홀수 필터는 부호 반전 (p%%4 순환)\n");
    printf("타일당 누산 증가: 출력의 1/8 (예: +4.0이면 0.5씩 8번)\n");
    return 0;
}
