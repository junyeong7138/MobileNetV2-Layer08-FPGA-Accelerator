# rev1 — PW1 발표 제출판 (동결 baseline) 🔒

**이 폴더는 수정하지 않는다.** 2026-08 PW1 발표·제출 시점의 코드 그대로이며,
발표 실측 수치의 재현과 이후 개선(rev2~)의 before 비교 기준으로만 쓴다.

## 검증 완료 실측 (발표 수치)

| 항목 | 값 |
|---|---|
| 최종 출력 | **75,264개 전수 비트 일치** (behavioral + post-synth 스모크) |
| 총 클럭 | **pw_done @87,169클럭** = 384타일 × 227 (LOAD 8 + CALC 196 + DRAIN 23) |
| 곱셈기 활용률 | 86.3% (타일당 31클럭 idle — 피드백 ④의 개선 대상 → rev2) |
| Utilization (ZU3EG) | LUT 2,501 (3.5%) · FF 6,707 (4.8%) · DSP 65 (18.1%) · BRAM 22.5 (10.4%) — mult IP "Use Mults" 확정판 |

## 구조

```
Layer08.v                    -- 톱 (검증 포트: out_valid/out_data/out_pos 스트림 노출)
Pointwise_Conv/
  PointWise_Conv.v           -- pw_engine: 주소 생성 + 하위 모듈 배선 (노션 스펙 §6.1)
  Ctrl_FSM.v                 -- IDLE→LOAD→CALC→DRAIN 타일 2중 루프, 열별 valid 윈도우
  SystolicArray.v            -- 8×8 Weight-Stationary PE 배열 (배선만 있는 껍데기)
  ProcessingElement.v        -- w_reg + mult_gen_0(16s×16s, 4단) + psum 누산
  Skew_Regs.v                -- 행 i를 i클럭 지연 (skew 계단)
  Accum_Buffer.v             -- 8뱅크×196×32b, 채널 타일 간 부분합 누산 + de-skew 주소
  Post_Proc.v                -- bias(BN 폴딩) + ReLU6 + 재양자화 (제출 범위에서는 제외)
```

## 재현 방법

- 시뮬레이션은 상위 공용 `../../sim/` 사용 — 실행 명령은 `tb_Layer08.v` 헤더 주석 참조.
- `sim/mult_gen_0.v`·`blk_mem_*.v`는 시뮬 전용 스텁 — **Vivado 프로젝트에 추가 금지** (실제 IP와 이름 충돌).

## 주의

- rev1/rev2/rev3의 모듈 이름이 전부 동일하다 — **한 시뮬레이션/Vivado 프로젝트에는 반드시 한 rev만** 넣을 것.

## 문서

- 노션 「3-1. Pointwise Conv 설계하기」(구현·검증), 「3-2. 발표 피드백 · 대안 · 고찰」(실측 표·피드백), 「2. 나만의 스펙 정하기」(소스 주석의 "노션 스펙 §n.n").
