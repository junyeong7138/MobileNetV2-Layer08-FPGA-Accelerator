# Layer08/model — 고정소수점 골든 모델 & 데이터 변환 유틸

폴더 구분 (2026-08-03 정리):

```
model/
├── src/      C 소스 (사람이 편집하는 것)
│   ├── fixp_layer08.c     고정소수점(int16) Layer08 골든 모델 — float 골든 대비 검증 + RTL 골든 벡터 생성
│   ├── make_input_coe.c   layer07 결과(bin) → 입력 버퍼용 .coe/.hex (8채널 128b 패킹, Q3.12)
│   ├── make_weight_coe.c  expand 가중치 → 가중치 버퍼용 .coe/.hex (타일 순서 + shift-in 역순) + bias hex
│   └── make_debug_coe.c   디버그용 소규모 .coe/.hex (Data/Debug/)
├── golden/   fixp_layer08이 생성하는 RTL 검증 골든 (fixp_stage1/2_uq313, fixp_out_q312)
└── build/    컴파일 산출물 (재생성 가능 — 지워도 됨)
```

**빌드·실행은 반드시 `model/` 폴더에서** (fopen 상대경로 기준):

```sh
cd Layer08/model
gcc src/make_input_coe.c  -o build/make_input_coe  -lm && ./build/make_input_coe   # → ../../Data/Input_Data/
gcc src/make_weight_coe.c -o build/make_weight_coe -lm && ./build/make_weight_coe  # → ../../Data/Weight/
gcc src/make_debug_coe.c  -o build/make_debug_coe  -lm && ./build/make_debug_coe   # → ../../Data/Debug/
gcc src/fixp_layer08.c    -o build/fixp_layer08    -lm && ./build/fixp_layer08     # → golden/
```

- 원본 데이터 출처: `../../../C_Programming/MobileNet_V2_C/MobileNet_v2/*.bin` (수업 제공 float32),
  가중치 헤더 `mobilenetv2_parameters.h` (#include, 소스 위치 기준 상대경로 — src/ 이동에 맞춰 보정됨).
- 생성물 소비처: `.coe` → Vivado BMG IP 초기화, `.hex` → 시뮬 `$readmemh`, `golden/` → TB 비교(Post_Proc 복원 시).
- 스펙 근거: 노션 「2. 나만의 스펙 정하기」 §4.5(Q 포맷)·§5.2(패킹 규칙).
