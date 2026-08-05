# ==========================================================
# vivado_open_rev.tcl — rev별 Vivado 프로젝트 생성 (Windows PC용)
#
# RV32I 때 VCS -f 파일리스트로 rev를 골라 열던 워크플로의 Vivado 판.
# rev 간 모듈명이 동일해서 한 프로젝트에 섞으면 안 되므로,
# rev마다 "별도 프로젝트"를 만들되 소스는 iCloud 원본을 참조한다
# ("Copy sources into project" 미사용과 동일 — 수정이 그대로 반영).
#
# 사용법 (Vivado Tcl Console):
#   set REV rev3                            ;# rev1 / rev2 / rev3
#   source {C:/Users/korea/iCloudDrive/(교육)RTL 취업연계 교육/5_실습/MobileNetV2/Layer08/scripts/vivado_open_rev.tcl}
#
# 또는 배치 실행:
#   vivado -mode gui -source vivado_open_rev.tcl
#   (REV 미지정 시 기본 rev1)
#
# ⚠ iCloud 한글 경로에서 add_files가 실패하면 (Vivado 한글 경로 미지원):
#   관리자 cmd:  mklink /J C:\hdl_src "C:\Users\korea\iCloudDrive\(교육)RTL 취업연계 교육\5_실습\MobileNetV2\Layer08"
#   후 아래 SRC를 C:/hdl_src 로 변경.
# ==========================================================

if {![info exists REV]} { set REV rev1 }

set SRC  "C:/Users/korea/iCloudDrive/(교육)RTL 취업연계 교육/5_실습/MobileNetV2/Layer08"
set PROJ "C:/ETRI_junyeong/vivado/layer08_${REV}"

# Ultra96-V2 (ZU3EG) — 파트 넘버는 보드 파일 기준으로 확인 후 필요 시 수정
create_project -force layer08_${REV} ${PROJ} -part xczu3eg-sbva484-1-i

# rev 소스 전체 (디렉터리 재귀 추가, 원본 참조)
add_files ${SRC}/rtl/${REV}

# 테스트벤치 (sim_1 전용)
#   ⚠ sim/의 IP 스텁(mult_gen_0.v, blk_mem_*.v)은 절대 추가 금지 —
#     Vivado 안에서는 실제 IP와 이름 충돌 (iverilog 전용 스텁)
add_files -fileset sim_1 [glob -nocomplain ${SRC}/sim/tb_*.v]
add_files -fileset sim_1 [glob -nocomplain ${SRC}/sim/*.memh]

# 톱은 rev/작업에 따라 다르므로 수동 지정:
#   set_property top PointWise_Conv [get_filesets sources_1]   ;# 예시
#   set_property top tb_Window_Gen  [get_filesets sim_1]

puts "=============================================="
puts " layer08_${REV} 프로젝트 생성 완료"
puts " 소스: ${SRC}/rtl/${REV} (원본 참조)"
puts " 다른 rev로 전환: set REV rev2; source 이 파일"
puts "=============================================="
