# rev3 — DW(Depthwise Conv) 독립 실습 + SA 공용화 🚧

이사님 지시(2026-08-04)에 따른 **2번째 실습**: 앞 단(PW1) 결과를 데이터패스로 직접
체이닝하지 않고, **별도 .coe로 떠서 BRAM에서 읽어** DW를 독립적으로 완결 설계·검증한다.
동시에 PE/SA를 공용 폴더로 분리해 PW·DW가 같은 부품을 파라미터로 공유한다.

## 구조

```
Layer08.v                    -- 톱 (통합 시퀀싱은 이후 단계)
SystolicArray/               -- ★ 공용 부품 (PW·DW 공유)
  ProcessingElement.v        -- X_UNSIGNED 파라미터 + generate로 곱셈 IP 선택
                             --   0: mult_gen_0 (16s×16s, PW용) / 1: mult_gen_1 (16u×16s, DW용)
  SystolicArray.v            -- PE_ROW/PE_COL/X_UNSIGNED 전부 파라미터 (판단 없는 껍데기)
Pointwise_Conv/              -- PW1 (SA가 공용 폴더로 빠진 버전)
  PointWise_Conv.v, Ctrl_FSM.v, Accum_Buffer.v, Post_Proc.v, Skew_Regs.v
Depthwise_Conv/
  Depthwise_Conv.v           -- DW 톱 — PW 복사 후 개조 진행 중 (모듈명 개명 완료)
```

## DW 스펙 요약 (상세: 노션 4-1 §3·§4)

- **매핑**: SA를 `PE_ROW=9, PE_COL=1, X_UNSIGNED=1`로 인스턴스. 행 = 3×3 커널의 9탭,
  열 psum 체인 = 9탭 합 → 열 바닥이 곧 DW 완성값 스트림(클럭당 1출력). **곱셈기 9개.**
- 채널 병렬이 필요해지면(퓨전 단계) 9×1 인스턴스를 복제 — 열 확장은 불가(열은 x를 공유하는데 DW는 채널마다 다른 x).
- **Accum_Buffer 불필요** (채널 타일 누산이 없음), de-skew도 단일 열이라 소멸.
- 입출력: 입력 = PW1 후처리 완료값 UQ3.13 (384ch × 14×14, coe) / 가중치 3,456개 (Q 포맷 실측 후 결정) / 출력 75,264개 → 골든 전수 비트 일치 채점 (PW 하네스 패턴 재사용).
- **Window_Gen = 윈도우 방출 방식 (확정 2026-08-05)**: 클럭당 완성 윈도우 1개, 채널당 정확히 196클럭.
  탭별 픽셀 매핑·패딩 0 주입 스펙 = `Docs/rev3(depthwise_conv)/Depthwise연산.xlsx` (196행 전수 열거
  — Window_Gen 단위 TB의 골든으로 사용). 성립 조건: PREFILL ~16클럭 선읽기(클럭 1이 픽셀 16까지 필요),
  이후 읽기 포인터가 방출보다 15~16픽셀 선행(1픽셀/클럭).
- FSM 타임라인: LOAD 9 → PREFILL ~16 → CALC 196 → DRAIN ~14(WG단+사다리9+MUL_LAT4+MEM_LAT1) → 분기.
  valid = PW식 연속 윈도우 [OFFSET, OFFSET+196), out_pos = 0~195 카운터.
- 예상 클럭: 채널당 ~235 × 384 ≈ **90k** (단순판) → PREFILL/DRAIN 겹침 ~85k → 가중치 섀도까지 ~76k.

## ⚠ 부호 함정

DW 입력 UQ3.13은 unsigned (최대 6.0 = 49152 > signed 16b 최대 32767).
`mult_gen_0`에 넣으면 큰 값이 음수로 오독된다 → **`mult_gen_1` IP 신규 생성 필수**:
Port A = Unsigned(x), Port B = Signed(w), **Pipeline Stages = 4 (MUL_LAT 계약 유지)**.

## 남은 작업

- [ ] `Depthwise_Conv.v` 개조 완료 — PW 잔재 제거 (Accum_Buffer 인스턴스 삭제, 주소 생성 재작성)
- [ ] `Window_Gen.v` 신규 — 라인버퍼 2줄 + 3×3 윈도우 + pad 경계 0 주입 → 9탭 스트림
- [ ] `Ctrl_FSM_DW.v` 신규 — 채널 384회 단일 루프 (⚠ 모듈명 PW의 Ctrl_FSM과 다르게)
- [ ] Skew_Regs를 SystolicArray/(공용)로 이동 검토 — DW도 사용 (PE_ROW=9로 인스턴스만)
- [ ] Vivado에서 `mult_gen_1` 생성 + `sim/mult_gen_1.v` 스텁 추가 (`P = $signed({1'b0,A}) * $signed(B)`)
- [ ] C 모델(fixp) DW 단계 추가 → 입력 coe·가중치 coe·골든 bin 생성, |w| 실측으로 Q 포맷 확정
- [ ] 단위 TB(Window_Gen) → 통합 TB(75,264개 전수 비트 일치) → post-synth

## 주의

- rev 간 모듈명 동일 — 한 시뮬/Vivado 프로젝트에 한 rev만.
- rev3 안에서도 PW·DW가 최종 통합 시 공존하므로 **신규 모듈명은 PW와 절대 겹치지 않게** (Ctrl_FSM_DW 등).
