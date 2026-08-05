//==========================================================
// make_weight_coe.c — B 메모리(가중치 버퍼 128b×3,072)용 COE 생성
//                     (Layer08 ① PW expand 64→384 단계)
//
// 변환 : BN 폴딩(w' = w·γ/√(var+ε)) → 2^-16 스케일 int16 양자화
//        — fixp_layer08.c의 fold_quant_params()와 동일 규칙!
//
// 패킹 : 주소 addr = (f_tile×N_CTILE + c_tile)×PE_ROW + k
//        (Ctrl_FSM의 LOAD 읽기 주소 공식과 1:1 — load_cnt = k)
//
//        ⚠ shift-in 역순: 먼저 넣은 값이 맨 아래 행까지 밀리므로
//          k=0 워드 = "행 7"의 가중치, k=7 워드 = "행 0"의 가중치
//
//        워드 [16j+15 : 16j] = 열 j = 필터 (f_tile×8 + j),
//        행 i = 채널 (c_tile×8 + i)
//        즉 워드(addr, 슬라이스 j) = W[f_tile×8+j][c_tile×8+(7-k)]
//
// 출력 : Data/Weight/layer08_expand_w_q16_128x3072.coe  (Vivado BMG용)
//        Data/Weight/layer08_expand_w_q16_128x3072.hex  ($readmemh 시뮬용)
//        Data/Weight/layer08_expand_bias_q28_256x48.hex (bias ROM — post_proc용)
//          bias는 BN 폴딩 후 누산기 스케일(2^-28) 32b, 8레인(=필터 8개) 팩 256b × 48타일
//          레인 j 슬라이스 [32j+31:32j] = 필터 (filter_tile*8 + j) — fixp_layer08.c와 동일 계산
//
// 빌드/실행 (이 폴더 model/ 에서):
//   gcc make_weight_coe.c -o make_wcoe -lm && ./make_wcoe
//
// 참고: bias(누산기 스케일 32b)는 post_proc 소관 — 별도 작은 메모리로 추후 생성.
//       ③ proj(384→64)는 N_CTILE=48/N_FTILE=8로 뒤집으면 같은 방식 (깊이 동일 3,072).
//==========================================================
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>

#include "../../../../C_Programming/MobileNet_V2_C/mobilenetv2_parameters.h"

#define IN_CH   64
#define EXP_CH  384
#define PE_ROW  8
#define PE_COL  8
#define N_CTILE (IN_CH/PE_ROW)      // 8
#define N_FTILE (EXP_CH/PE_COL)     // 48
#define DEPTH   (N_FTILE*N_CTILE*PE_ROW)    // 3,072

#define EPSILON 1e-05
#define F_WE    16                  // expand 가중치 2^-16 스케일

// fixp_layer08.c와 동일한 양자화 (round-half-up + int16 포화)
static int16_t quant16 (double v, int frac)
{
    double s = floor(v * (double)(1LL << frac) + 0.5);
    if (s >  32767.0) return  32767;
    if (s < -32768.0) return -32768;
    return (int16_t)s;
}

static int16_t wq[EXP_CH*IN_CH];    // [OC][IC], BN 폴딩+양자화 완료본

int main (void)
{
    // BN 폴딩 + 양자화 (fixp_layer08.c fold_quant_params()의 expand 부분)
    for (int oc = 0; oc < EXP_CH; oc++) {
        double s = features_8_conv_0_1_weight[oc] / sqrt(features_8_conv_0_1_running_var[oc] + EPSILON);
        for (int ic = 0; ic < IN_CH; ic++)
            wq[oc*IN_CH+ic] = quant16(features_8_conv_0_0_weight[oc*IN_CH+ic] * s, F_WE);
    }

    FILE *fcoe = fopen("../../Data/Weight/layer08_expand_w_q16_128x3072.coe", "w");
    FILE *fhex = fopen("../../Data/Weight/layer08_expand_w_q16_128x3072.hex", "w");
    if (!fcoe || !fhex) { printf("FAIL: 출력 파일 생성 실패 (Data/Weight/ 존재 확인)\n"); return 1; }

    fprintf(fcoe, "; B 메모리 (가중치 버퍼) 128b x %d — Layer08 PW expand, BN 폴딩 + 2^-16 int16\n", DEPTH);
    fprintf(fcoe, "; addr = (f_tile*%d + c_tile)*%d + k,  k=0 워드가 행7 (shift-in 역순)\n", N_CTILE, PE_ROW);
    fprintf(fcoe, "; [16j+15:16j] = 필터(f_tile*8+j), 행 = 채널(c_tile*8 + (7-k))\n");
    fprintf(fcoe, "memory_initialization_radix=16;\n");
    fprintf(fcoe, "memory_initialization_vector=\n");

    for (int addr = 0; addr < DEPTH; addr++) {
        int f_tile = addr / (N_CTILE*PE_ROW);
        int c_tile = (addr / PE_ROW) % N_CTILE;
        int k      = addr % PE_ROW;
        int ic     = c_tile*PE_ROW + (PE_ROW-1-k);      // shift-in 역순의 핵심
        // 열 7(상위 hex) → 열 0(하위 hex)
        for (int j = PE_COL-1; j >= 0; j--) {
            uint16_t code = (uint16_t)wq[(f_tile*PE_COL+j)*IN_CH + ic];
            fprintf(fcoe, "%04x", code);
            fprintf(fhex, "%04x", code);
        }
        fprintf(fcoe, (addr == DEPTH-1) ? ";\n" : ",\n");
        fprintf(fhex, "\n");
    }
    fclose(fcoe);
    fclose(fhex);

    // ---- bias ROM hex (post_proc용, 누산기 스케일 f=28) ----
    {
        FILE *fb = fopen("../../Data/Weight/layer08_expand_bias_q28_256x48.hex", "w");
        if (!fb) { printf("FAIL: bias hex 생성 실패\n"); return 1; }
        for (int ft = 0; ft < N_FTILE; ft++) {
            for (int j = PE_COL-1; j >= 0; j--) {           // 레인 7(상위 hex) → 레인 0
                int oc = ft*PE_COL + j;
                double s = features_8_conv_0_1_weight[oc] / sqrt(features_8_conv_0_1_running_var[oc] + EPSILON);
                double bf = features_8_conv_0_1_bias[oc] - features_8_conv_0_1_running_mean[oc] * s;
                int32_t code = (int32_t)floor(bf * (double)(1LL << 28) + 0.5);  // fixp와 동일 규칙
                fprintf(fb, "%08x", (uint32_t)code);
            }
            fprintf(fb, "\n");
        }
        fclose(fb);
    }

    // 검증용 미리보기: addr 0 = f_tile0/c_tile0/k0 → 행7(ic=7)의 필터 7..0
    printf("=== layer08_expand_w_q16_128x3072.coe (%d words) ===\n", DEPTH);
    printf("addr 0 미리보기 = 행7(ic=7), 폴딩 float → 2^-16 코드:\n");
    for (int j = PE_COL-1; j >= 0; j--) {
        double s = features_8_conv_0_1_weight[j] / sqrt(features_8_conv_0_1_running_var[j] + EPSILON);
        double wf = features_8_conv_0_0_weight[j*IN_CH+7] * s;
        printf("  필터%d: %+.6f -> %6d (0x%04x)\n", j, wf, wq[j*IN_CH+7], (uint16_t)wq[j*IN_CH+7]);
    }
    printf("PASS\n");
    return 0;
}
