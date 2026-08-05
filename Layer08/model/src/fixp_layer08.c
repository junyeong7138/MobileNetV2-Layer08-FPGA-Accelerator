//==========================================================
// fixp_layer08.c — MobileNetV2 features[8] 고정소수점(int16) 모델
// (노션 스펙 §4.5 확정 Q 포맷 / §7 검증 체계 — RTL의 비트 단위 골든)
//
// 파이프라인 (RTL post_proc와 동일 순서, 동일 반올림 규칙이어야 함):
//   ① PW expand 64→384 : Q3.12 × w(2^-16) → acc(f28) → +bias → ReLU6 → ≫15 → UQ3.13
//   ② DW 3×3 s1 p1     : UQ3.13 × w(2^-11) → acc(f24) → +bias → ReLU6 → ≫11 → UQ3.13
//   ③ PW proj 384→64   : UQ3.13 × w(2^-14) → acc(f27) → +bias →         ≫15 → Q3.12 포화
//   ④ residual         : ③ 결과 + 입력(Q3.12) 정수 덧셈 → 포화
//
//   반올림: round-half-up = (acc + 2^(s-1)) >> s (산술 시프트) — RTL과 반드시 동일!
//   BN은 가중치에 폴딩: w' = w·γ/√(var+ε), b' = β − mean·γ/√(var+ε), ε=1e-5
//
// 빌드/실행 (이 폴더 model/ 에서):
//   gcc fixp_layer08.c -o fixp -lm && ./fixp
//
// 출력:
//   - float 골든(mobilenetv2_result_layer08.bin) 대비 통계 (판정 기준 1e-2)
//   - RTL 골든 벡터 3종: fixp_stage1_uq313.bin / fixp_stage2_uq313.bin /
//                        fixp_out_q312.bin  (int16 raw, [C][H][W] 채널-major)
//   - 단계별 누산기 최대 비트폭 (32b SVA 논증용 실측치)
//==========================================================
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdint.h>

#include "../../../../C_Programming/MobileNet_V2_C/mobilenetv2_parameters.h"

#define IN_CH   64
#define EXP_CH  384
#define OUT_CH  64
#define HW      14
#define SP      (HW*HW)         // 196

#define EPSILON 1e-05

// ---- Q 포맷 (스펙 §4.5 확정) ----
#define F_IN    12              // 입력·최종출력 Q3.12
#define F_MID   13              // 중간 활성 UQ3.13
#define F_WE    16              // expand 가중치 2^-16
#define F_WD    11              // DW 가중치 2^-11
#define F_WP    14              // proj 가중치 2^-14
#define S1      15              // 재양자화 시프트: (12+16)-13
#define S2      11              //                 (13+11)-13
#define S3      15              //                 (13+14)-12

#define INPUT_FILE  "../../../C_Programming/MobileNet_V2_C/MobileNet_v2/mobilenetv2_result_layer07.bin"
#define GOLDEN_FILE "../../../C_Programming/MobileNet_V2_C/MobileNet_v2/mobilenetv2_result_layer08.bin"

//==========================================================
// 유틸

// float → 정수코드, round-half-up (RTL과 동일 규칙; rint의 half-to-even 금지)
static int32_t quant (double v, int frac)
{
    return (int32_t)floor(v * (double)(1LL << frac) + 0.5);
}

static int16_t sat16 (int64_t v)
{
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

// round-half-up 재양자화: 2^(s-1) 가산 후 산술 시프트
static int64_t requant (int64_t acc, int shift)
{
    return (acc + (1LL << (shift-1))) >> shift;
}

static int bits_of (int64_t v)      // 부호 포함 최소 비트수
{
    int64_t a = (v < 0) ? -v : v;
    int b = 1;
    while (a) { b = b + 1; a >>= 1; }
    return b;
}

static float* load_f32 (const char *path, int n)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) { printf("FAIL: %s 열기 실패 (model/ 에서 실행했는지 확인)\n", path); exit(1); }
    float *buf = (float*)malloc(sizeof(float)*n);
    if (fread(buf, sizeof(float), n, fp) != (size_t)n) { printf("FAIL: %s 크기 이상\n", path); exit(1); }
    fclose(fp);
    return buf;
}

static void dump_i16 (const char *path, const int32_t *src, int n)
{
    FILE *fp = fopen(path, "wb");
    if (!fp) { printf("FAIL: %s 쓰기 실패\n", path); exit(1); }
    for (int i = 0; i < n; i++) { int16_t v = (int16_t)src[i]; fwrite(&v, sizeof(int16_t), 1, fp); }
    fclose(fp);
}

//==========================================================
// BN 폴딩 + 양자화 (오프라인 파라미터 유틸의 원형 — 이후 hex 추출도 여기서 파생)

static int16_t wq_e[EXP_CH*IN_CH];      // expand  [OC][IC]
static int16_t wq_d[EXP_CH*9];          // DW      [C][3x3]
static int16_t wq_p[OUT_CH*EXP_CH];     // proj    [OC][IC]
static int64_t bq_e[EXP_CH];            // bias는 누산기 스케일 (f28/f24/f27)
static int64_t bq_d[EXP_CH];
static int64_t bq_p[OUT_CH];

static void fold_quant_params (void)
{
    for (int oc = 0; oc < EXP_CH; oc++) {
        double s = features_8_conv_0_1_weight[oc] / sqrt(features_8_conv_0_1_running_var[oc] + EPSILON);
        for (int ic = 0; ic < IN_CH; ic++)
            wq_e[oc*IN_CH+ic] = sat16(quant(features_8_conv_0_0_weight[oc*IN_CH+ic] * s, F_WE));
        bq_e[oc] = quant(features_8_conv_0_1_bias[oc] - features_8_conv_0_1_running_mean[oc] * s, F_IN + F_WE);
    }
    for (int c = 0; c < EXP_CH; c++) {
        double s = features_8_conv_1_1_weight[c] / sqrt(features_8_conv_1_1_running_var[c] + EPSILON);
        for (int k = 0; k < 9; k++)
            wq_d[c*9+k] = sat16(quant(features_8_conv_1_0_weight[c*9+k] * s, F_WD));
        bq_d[c] = quant(features_8_conv_1_1_bias[c] - features_8_conv_1_1_running_mean[c] * s, F_MID + F_WD);
    }
    for (int oc = 0; oc < OUT_CH; oc++) {
        double s = features_8_conv_3_weight[oc] / sqrt(features_8_conv_3_running_var[oc] + EPSILON);
        for (int ic = 0; ic < EXP_CH; ic++)
            wq_p[oc*EXP_CH+ic] = sat16(quant(features_8_conv_2_weight[oc*EXP_CH+ic] * s, F_WP));
        bq_p[oc] = quant(features_8_conv_3_bias[oc] - features_8_conv_3_running_mean[oc] * s, F_MID + F_WP);
    }
}

//==========================================================

static int32_t xq   [IN_CH*SP];         // 입력 Q3.12
static int32_t act1 [EXP_CH*SP];        // ① 출력 UQ3.13
static int32_t act2 [EXP_CH*SP];        // ② 출력 UQ3.13
static int32_t outq [OUT_CH*SP];        // ④ 출력 Q3.12

int main (void)
{
    float *x_f      = load_f32(INPUT_FILE,  IN_CH*SP);
    float *golden_f = load_f32(GOLDEN_FILE, OUT_CH*SP);

    fold_quant_params();

    // 입력 양자화 (Q3.12)
    for (int i = 0; i < IN_CH*SP; i++)
        xq[i] = sat16(quant(x_f[i], F_IN));

    int64_t max_acc1 = 0, max_acc2 = 0, max_acc3 = 0;

    //--------------------------------------------------
    // ① PW expand 64→384 → +bias → ReLU6 → ≫15 → UQ3.13
    //    (RTL: SA 열 내적 + accum_buffer + post_proc 경로와 동일)
    //--------------------------------------------------
    for (int oc = 0; oc < EXP_CH; oc++)
        for (int p = 0; p < SP; p++) {
            int64_t acc = 0;
            for (int ic = 0; ic < IN_CH; ic++)
                acc += (int64_t)xq[ic*SP+p] * wq_e[oc*IN_CH+ic];
            acc += bq_e[oc];
            if (llabs(acc) > max_acc1) max_acc1 = llabs(acc);
            if (acc < 0)                        acc = 0;                    // ReLU6 (누산기 스케일 f28)
            if (acc > (6LL << (F_IN+F_WE)))     acc = 6LL << (F_IN+F_WE);
            act1[oc*SP+p] = (int32_t)requant(acc, S1);                      // ≤ 6·2^13 = 49152
        }

    //--------------------------------------------------
    // ② DW 3×3 stride1 pad1 → +bias → ReLU6 → ≫11 → UQ3.13
    //--------------------------------------------------
    for (int c = 0; c < EXP_CH; c++)
        for (int oy = 0; oy < HW; oy++)
            for (int ox = 0; ox < HW; ox++) {
                int64_t acc = 0;
                for (int ky = 0; ky < 3; ky++)
                    for (int kx = 0; kx < 3; kx++) {
                        int iy = oy + ky - 1, ix = ox + kx - 1;
                        if (iy < 0 || iy >= HW || ix < 0 || ix >= HW) continue;   // zero-pad
                        acc += (int64_t)act1[c*SP + iy*HW + ix] * wq_d[c*9 + ky*3 + kx];
                    }
                acc += bq_d[c];
                if (llabs(acc) > max_acc2) max_acc2 = llabs(acc);
                if (acc < 0)                        acc = 0;                // ReLU6 (f24)
                if (acc > (6LL << (F_MID+F_WD)))    acc = 6LL << (F_MID+F_WD);
                act2[c*SP + oy*HW + ox] = (int32_t)requant(acc, S2);
            }

    //--------------------------------------------------
    // ③ PW proj 384→64 → +bias → ≫15 → Q3.12 포화 (Linear — ReLU 없음!)
    // ④ residual: + 입력 Q3.12 → 포화
    //--------------------------------------------------
    for (int oc = 0; oc < OUT_CH; oc++)
        for (int p = 0; p < SP; p++) {
            int64_t acc = 0;
            for (int ic = 0; ic < EXP_CH; ic++)
                acc += (int64_t)act2[ic*SP+p] * wq_p[oc*EXP_CH+ic];
            acc += bq_p[oc];
            if (llabs(acc) > max_acc3) max_acc3 = llabs(acc);
            int16_t proj = sat16(requant(acc, S3));
            outq[oc*SP+p] = sat16((int64_t)proj + xq[oc*SP+p]);             // residual (동일 Q3.12)
        }

    //--------------------------------------------------
    // 검증 1단계: float 골든 대비 통계 (스펙 §7, 기준 1e-2)
    //--------------------------------------------------
    double max_err = 0.0, sq_sum = 0.0;
    int mismatch = 0;
    for (int i = 0; i < OUT_CH*SP; i++) {
        double err = fabs((double)outq[i] / (1 << F_IN) - golden_f[i]);
        if (err > max_err) max_err = err;
        sq_sum += err*err;
        if (err > 1e-2) mismatch = mismatch + 1;
    }

    printf("=== fixp_layer08 (int16 F안) vs float 골든 ===\n");
    printf("불일치(>1e-2) : %d / %d\n", mismatch, OUT_CH*SP);
    printf("최대 오차     : %.6f\n", max_err);
    printf("RMSE          : %.6f\n", sqrt(sq_sum/(OUT_CH*SP)));
    printf("누산기 최대   : ①%2d비트  ②%2d비트  ③%2d비트  (RTL 32b 한계 대비)\n",
           bits_of(max_acc1), bits_of(max_acc2), bits_of(max_acc3));
    printf("%s\n", (mismatch == 0) ? "PASS" : "FAIL");

    // RTL 골든 벡터 (int16 raw, 채널-major)
    dump_i16("golden/fixp_stage1_uq313.bin", act1, EXP_CH*SP);
    dump_i16("golden/fixp_stage2_uq313.bin", act2, EXP_CH*SP);
    dump_i16("golden/fixp_out_q312.bin",     outq, OUT_CH*SP);
    printf("골든 벡터 저장(golden/): fixp_stage1_uq313.bin / fixp_stage2_uq313.bin / fixp_out_q312.bin\n");

    free(x_f);
    free(golden_f);
    return (mismatch == 0) ? 0 : 1;
}
