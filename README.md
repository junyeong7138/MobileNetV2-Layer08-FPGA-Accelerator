# 🧠 MobileNetV2 Layer08 FPGA Accelerator

MobileNetV2의 **Inverted Residual Bottleneck(Layer 08)** 을 FPGA 가속기로 설계하는 프로젝트입니다.
C 골든 모델 → 고정소수점 모델 → Verilog RTL의 순서로 내려가며,
1×1 Pointwise Convolution을 **8×8 Weight-Stationary Systolic Array**로 구현해
**출력 75,264개 전부를 골든 모델과 비트 단위로 일치**시켜 검증했습니다.
같은 Systolic Array 부품을 9×1로 재구성해 Depthwise Convolution까지 확장하고 있습니다.

| 항목 | 내용 |
|---|---|
| 타깃 | Ultra96-V2 (Zynq UltraScale+ **ZU3EG**) |
| 대상 레이어 | MobileNetV2 features[8] — PW expand(64→384) → DW 3×3 → PW project(384→64) |
| 아키텍처 | Weight-Stationary Systolic Array — PW: 8×8 (DSP 64), DW: 9×1 (행=3×3 탭) |
| 수치 표현 | 텐서별 실측 동적 범위 기반 고정소수점 — 입력 Q3.12, 활성 UQ3.13, 누산 32b |
| 검증 | PW1 최종 출력 **75,264개 전수 비트 일치** (behavioral + post-synthesis) |
| 성능 | PW1 87,169클럭 (곱셈기 활용률 86.3%) → 가중치 더블 버퍼링으로 **75.3k클럭 / 99.9%** 개선 진행 |
| Utilization | LUT 2,501 (3.5%) · FF 6,707 (4.8%) · DSP 65 (18.1%) · BRAM 22.5 (10.4%) |

## 📂 Contents

1. [👨‍💻 Who Made?](#-who-made)
2. [🌳 개발환경](#-개발환경)
3. [🔧 개발과정](#-개발과정)
4. [🧮 HW Architecture](#-hw-architecture)
5. [✅ Verification](#-verification)
6. [⚡ 성능 분석과 개선](#-성능-분석과-개선)
7. [📁 Repository Guide](#-repository-guide)

## 👨‍💻 Who Made?

박준영 (JuNyeong Park) — ETRI 디지털 RTL 회로설계 교육 최종 프로젝트

[@junyeong7138](https://github.com/junyeong7138)

## 🌳 개발환경

| 설계 언어 | 골든 모델 | Simulation | 합성/구현 | 보드 |
|---|---|---|---|---|
| Verilog | C (float → 고정소수점 2단) | Icarus Verilog(사전 검증) + Vivado xsim(post-synth) | Vivado | Ultra96-V2 (ZU3EG) |

## 🔧 개발과정

리비전을 나눠 엔진을 하나씩 얹고, 리비전마다 전수 비트 일치 채점으로 검증하며 진행합니다.

| Rev | 내용 | 상태 |
|---|---|---|
| `rev1` | **PW1 엔진** — 8×8 WS Systolic Array + 8뱅크 누산 버퍼 + 타일링 FSM | ✅ 검증 완료 (75,264개 비트 일치, 87,169클럭, post-synth 통과) |
| `rev2` | **가중치 더블 버퍼링(풀 오버랩)** — 섀도 레지스터 + 데이터 동반 태그 스왑으로 타일 간 idle 31클럭 제거 | 🚧 설계 확정, 구현 중 (목표 75.3k클럭, 활용률 99.9%) |
| `rev3` | **DW 엔진** — SA를 9×1로 재구성(행=3×3 탭), 31단 지연선 윈도우 생성기 + 좌표 마스킹 패딩 | 🚧 RTL 배선 완료, 윈도우 생성기 단위검증 통과(1,764탭 전수), 골든 연동 진행 |

설계 문서(다이어그램·스케메틱·연산 스펙 엑셀)는 [`Docs/`](Docs)에 리비전별로 정리되어 있습니다.

## 🧮 HW Architecture

### Layer08 블록 흐름

MobileNetV2의 inverted residual bottleneck — PW expand → BN·ReLU6 → DW → BN·ReLU6 → PW project → BN (+residual):

![Layer08 block flow](<Docs/이미지/PointWise_Conv설계/01_layer08_block_flow.svg>)

### Pointwise Conv = GEMM → Systolic Array 매핑

1×1 conv는 순수 행렬곱(196×64 · 64×384)이므로 Systolic Array의 정석 매핑이 성립합니다.
행 = 입력 채널(8개 타일링), 열 = 출력 필터(8개 타일링), psum은 열 방향으로 누산:

![Systolic mapping](<Docs/이미지/PointWise_Conv설계/02_pointwise_systolic_mapping.svg>)

![SA animation](<Docs/rev1(pointwise_conv)/이미지/SA_animation.gif>)

### PW 엔진 블록도

`Ctrl_FSM`(타일 2중 루프·valid 윈도우) → `Skew_Regs`(행별 1클럭 계단) → `SystolicArray`(8×8 WS)
→ `Accum_Buffer`(8뱅크×196×32b — 열마다 쓰기 주소가 어긋나므로 뱅크 분리) → 출력 스트림:

![Engine block diagram](<Docs/이미지/PointWise_Conv설계/03_engine_block_diagram.svg>)

![전체 아키텍처](<Docs/rev1(pointwise_conv)/이미지/전체 아키텍처.png>)

### 설계 원칙

- **판단과 데이터패스의 분리** — 상태 인코딩·카운터는 FSM 내부에만, 어레이는 배선만 있는 껍데기
- **지연은 상수로 계약** — 곱셈기 4단(MUL_LAT)·메모리 1단(MEM_LAT)·skew를 valid 윈도우 오프셋 하나로 흡수
- **de-skew를 FF가 아니라 주소로** — 열별 시차를 누산 버퍼 쓰기 주소 계산으로 흡수
- **패딩은 저장이 아니라 마스킹** — DW의 zero padding은 좌표 조건부 mux 9개 (0클럭, 0메모리)
- **동시 접근 개수가 메모리 구조를 결정** — 같은 주소로 읽히면 와이드 워드(128b), 아니면 뱅크 분리

### 고정소수점 데이터패스

int8 실측 기각 → int16 채택. 텐서별 실측 동적 범위를 겨우 덮는 만큼만 정수부를 배정:

![Q-format datapath](<Docs/이미지/PointWise_Conv설계/04_qformat_datapath.svg>)

## ✅ Verification

**"골든 없이 RTL 없다"** — 3단 골든 체계로 검증했습니다.

1. **float C 모델** — PyTorch 레퍼런스와 대조 (최종 분류 Samoyed 일치)
2. **고정소수점 C 모델** — float 대비 불일치 0 확인, RTL의 비트 단위 기준점
3. **RTL** — 최종 출력 **75,264개 전수 비트 일치** 채점 (`sim/tb_Layer08.v`)
   - behavioral 시뮬 + **post-synthesis 시뮬**까지 동일 채점 통과
   - 서브모듈 단위 TB: PE·SystolicArray·Ctrl_FSM·Window_Gen(엑셀 연산 스펙 1,764탭 전수 비교)

![테스트벤치 결과](<Docs/rev1(pointwise_conv)/이미지/테벤 결과.png>)

Vivado 스케메틱(elaboration/synthesis)은 [`Docs/rev1(pointwise_conv)/스케메틱`](<Docs/rev1(pointwise_conv)/스케메틱>)에 모듈별로 정리했습니다.

## ⚡ 성능 분석과 개선

실측 87,169클럭을 정확히 분해하면 타일당 227클럭 = LOAD 8 + CALC 196 + DRAIN 23 —
**타일 간 31클럭(13.7%)은 곱셈기가 노는 시간**입니다 (파형으로 실측 확인).

| | rev1 (측정) | rev2 (설계 확정) |
|---|---|---|
| 총 클럭 | 87,169 | ~75,300 (이론 하한 75,264 + α) |
| 곱셈기 활용률 | 86.3% | 99.9% |
| 방법 | LOAD·DRAIN이 연산을 정지 | 섀도 레지스터에 다음 가중치를 **연산 중** 로드, 경계 태그가 데이터와 함께 전파되며 PE별 스왑 |

핵심 발견: 타일 경계는 행 단위가 아니라 **대각선 파면**(PE(i,j)의 경계 도착 시각 ∝ i+j)으로 지나가므로,
전역 스왑이나 행 단위 로드는 오답을 만든다. 경계 태그를 입력 데이터와 같은 경로(skew + 수평 전달)로
흘리면 대각선 타이밍이 추가 회로 없이 자동 생성된다.

같은 원리의 확장으로, 어레이당 클럭이 아니라 **클럭 × 곱셈기 수(= 곱셈기당 활용률)** 를 비교 지표로 삼아
DW(9 DSP)·PW2와의 스테이지 균형(배치 주기 레이트 매칭)까지 정량 설계했습니다.

## 📁 Repository Guide

```
MobileNetV2/
├── Layer08/
│   ├── model/                  # C 골든 모델 (float / 고정소수점) + 파라미터 유틸
│   ├── rtl/
│   │   ├── rev1/               # PW1 발표판 (동결 baseline) — README 참조
│   │   ├── rev2/               # PW1 풀 오버랩 작업 — README 참조
│   │   └── rev3/               # DW 독립 설계 + SA 공용화 — README 참조
│   │       ├── SystolicArray/  #   공용 PE/SA (X_UNSIGNED 파라미터로 PW·DW 곱셈기 선택)
│   │       ├── Pointwise_Conv/
│   │       └── Depthwise_Conv/ #   Window_Gen·Ctrl_FSM_DW·톱
│   ├── sim/                    # 공용 TB + 전수 채점 하네스 + 시뮬 전용 IP 스텁
│   └── scripts/                # rev별 Vivado 프로젝트 생성 Tcl
├── Data/                       # 입력/가중치 COE·hex, 레이어별 골든 텐서
└── Docs/                       # 설계 다이어그램·스케메틱·보고서·연산 스펙
```

각 rev 폴더의 `README.md`에 해당 리비전의 목표·설계 계획·검증 기준이 정리되어 있습니다.
⚠ rev 간 모듈 이름이 동일하므로 시뮬레이션/Vivado 프로젝트에는 **한 rev만** 포함해야 합니다.
