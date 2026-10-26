#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Mulei Zhang
# Linux frontend; camera algorithms and transaction decisions remain upstream.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail
COMMIT=ef7db116e13e37be91e9af20360dc9bba8d64a9b
URL=https://github.com/QAQLeonard/a7c2-fl23-research.git
SCRIPT=$(readlink -f -- "$0")
BASE=$(dirname -- "$SCRIPT")/a7c2-linux-data
SOURCE=$BASE/upstream-$COMMIT
PY=$BASE/.venv/bin/python
DATA=$BASE/state
CURRENT=$DATA/current
export A7C2_DESKTOP_DATA=$DATA A7C2_ZIG_CACHE=$BASE/zig-cache A7C2_SCRIPT=$SCRIPT
export PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1
unset PYTHONHOME PYTHONPATH
say() { printf '%s\n' "$*"; }
die() { say "$*" >&2; return 1; }
ask() { read -r -p "$1 " REPLY || return 1; }
yes() {
    say "$1"
    say '  1 确认 / 是    0 返回 / 否（默认）'
    while ask '请选择 [0]：'; do
        case $REPLY in
            1) return 0 ;;
            0|'') return 1 ;;
            *) say '只需输入 1 或 0。' ;;
        esac
    done
    return 1
}
action_title() {
    case $1 in
        connect) say '检查相机连接（只读）' ;; usb_stability) say '检测 USB 稳定性（只读，至少两分钟）' ;;
        setup_all) say '安装所选功能 / 继续安装' ;;
        direct_fl23_enable) say '启用 FL2 / FL3' ;; direct_fl23_disable) say '移除 FL2 / FL3 菜单入口' ;;
        direct_looks_import|direct_resume_looks) say '应用自定义外观' ;; direct_slot_default) say '将选定槽位恢复为 ST' ;;
        compile_look) say '转换 DCP / CUBE 外观文件（离线）' ;;
        direct_sound_enable) say '开启原生快门声音' ;; direct_sound_disable) say '关闭快门声音' ;;
        direct_sound_restore) say '恢复原厂快门音效' ;; sound_import) say '转换声音文件（离线）' ;;
        sound_install) say '安装自定义快门声音' ;;
        direct_factory_reset|direct_resume_factory) say '恢复原厂功能' ;;
        direct_verify|restore_verify) say '核对重启后的相机状态' ;;
        backup_inspect) say '检查历史备份（离线）' ;; restore) say '使用历史备份回退' ;;
        *) say '执行相机任务' ;;
    esac
}
confirm_write() {
    say ''; say "即将$(action_title "$1")"
    case $1 in
        setup_all) jq -r 'if .options.fl23 then "  · 启用 FL2 / FL3" else empty end,
            if .options.sound then "  · 开启原生快门声音" else empty end,
            (.options.looks[]? | "  · 写入自订 \(.slot)：\(.path | split("/") | last)")' <<<"$2" ;;
        direct_looks_import) jq -r '.operations[] | "  · 替换自订 \(.slot)：\(.path | split("/") | last)"' <<<"$2" ;;
        direct_slot_default) jq -r '"  · 自订 \(.slot) 将设为 ST，原配方无法恢复。"' <<<"$2" ;;
        direct_factory_reset|direct_resume_factory) say '  · 移除本项目的修改，自订 1–6 全部设为 ST；原配方无法恢复。' ;;
        restore) say '  · 回到所选备份的状态，可能撤销之后的外观和功能修改。' ;;
    esac
    say '请确认：相机为 A7C II、固件 2.01，电量至少 50%，供电和数据线稳定。'
    yes '已备份重要数据，并接受本次修改的风险，开始操作？'
}
help_text() {
    cat <<EOF
用法：sh a7c2-linux.sh [setup|doctor|status|continue|usb-help|test|help]
无参数进入交互菜单；setup 自动下载固定上游、创建本目录 venv 并安装依赖。
固定版本：$COMMIT。仅支持 ILCE-7CM2 固件 2.01；已在 Fedora 44 x86_64 实机验证。
需要 bash、git、jq、flock、Python 3.11 + venv；自动卸载分区需要 udisksctl。
面向 Debian/Ubuntu、Fedora/RHEL、Arch、openSUSE；其他发行版和硬件组合尚待实测。
菜单保留 FL2/FL3、A7Look、声音、组合安装和恢复；竖屏仍因上游重写而暂停。
不执行 sudo、不修改系统规则；usb-help 显示管理员准备步骤。
运行数据全部位于 $BASE，备份和事务不可删除来绕过错误。
setup/doctor/test 不访问相机；test 运行适配器检查和选定的上游离线测试。
读取上游事务状态进行续接，不改写其状态、不自动重试写入。说明与自检均在本文件。
上游代码遵循 PolyForm Noncommercial 1.0.0，第三方资源保留原许可，详见下载后的 LICENSE。
EOF
}
usb_help() {
    cat <<'EOF'
需由管理员配置两个 USB 身份的访问权限。原因：普通用户必须能打开 libusb 设备。
以下命令仅展示，本脚本不执行 sudo：
  sudo tee /etc/udev/rules.d/70-a7c2.rules <<'RULES'
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0e8a", MODE="0660", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="054c", ATTR{idProduct}=="0336", MODE="0660", TAG+="uaccess"
RULES
  sudo udevadm control --reload-rules
然后拔插 USB；SSH/无桌面会话需管理员另配专用用户组权限。
不要用 usb-storage quirks 忽略相机：普通存储驱动应先完成初始化。
脚本使用 udisksctl 卸载相机分区，之后调用上游 libusb 的内核驱动解绑方法。
EOF
}
setup() {
    local command stage
    for command in git jq flock python3.11; do command -v "$command" >/dev/null || die "缺少 $command，请先安装。" || return; done
    mkdir -p "$BASE" "$DATA/work"
    printf '*\n' > "$BASE/.gitignore"
    if [[ ! -d $SOURCE ]]; then
        stage=$(mktemp -d "$BASE/download.XXXXXX")
        git init -q "$stage"
        git -C "$stage" remote add origin "$URL"
        git -C "$stage" -c core.hooksPath=/dev/null fetch --depth=1 origin "$COMMIT"
        git -C "$stage" -c core.hooksPath=/dev/null checkout -q --detach "$COMMIT"
        mv -- "$stage" "$SOURCE"
    fi
    [[ $(git -C "$SOURCE" remote get-url origin) == "$URL" && $(git -C "$SOURCE" rev-parse HEAD) == "$COMMIT" &&
       -z $(git -C "$SOURCE" status --porcelain --untracked-files=all) ]] || { die '源码来源、版本或内容改变，停止；未覆盖缓存。'; return 1; }
    [[ -x $PY ]] || python3.11 -m venv "$BASE/.venv"
    "$PY" -c 'import sys; assert sys.version_info[:2] == (3,11) and sys.prefix != sys.base_prefix, "需要目录内 Python 3.11 venv"'
    sed '/^PySide6/d; /^#/d; /^$/d' "$SOURCE/desktop-requirements.txt" > "$BASE/requirements.txt"
    if ! cmp -s "$BASE/requirements.txt" "$BASE/installed-requirements.txt"; then
        "$PY" -m pip --isolated install --cache-dir "$BASE/pip-cache" -r "$BASE/requirements.txt"
        cp "$BASE/requirements.txt" "$BASE/installed-requirements.txt"
    fi
    export PYTHONPATH="$SOURCE/src:$SOURCE/src/looks:$SOURCE/src/camera_runtime:$SOURCE/src/camera_runtime/vendor:$SOURCE/src/shutter_sound"
    PATH="$("$PY" -c 'import pathlib,ziglang; print(pathlib.Path(ziglang.__file__).parent)'):$BASE/.venv/bin:$PATH"
    export PATH
    "$PY" "$SOURCE/lut.py" doctor --device > "$BASE/doctor.json"
    # Keep old adapter evidence; use its upstream job pointer without copying phases.
    if [[ ! -e $CURRENT && -f $DATA/pending.private.json ]]; then
        ln -s -- "$(jq -er .job "$DATA/pending.private.json")" "$CURRENT"
    fi
}
mounted() { awk -v dev="$(cat "$1/dev")" '$3 == dev {found=1} END {exit !found}' /proc/self/mountinfo; }
usb_prepare() {
    local dev pid intf driver block node real quirks
    local -a cameras=()
    for dev in /sys/bus/usb/devices/*; do
        [[ -r $dev/idVendor && $(cat "$dev/idVendor") == 054c ]] || continue
        pid=$(cat "$dev/idProduct")
        [[ $pid == 0e8a || $pid == 0336 ]] && cameras+=("$dev")
    done
    [[ ${#cameras[@]} == 1 ]] || { die '请仅连接一台 A7C II，以海量存储模式接入。'; return 1; }
    dev=${cameras[0]}; pid=$(cat "$dev/idProduct"); real=$(readlink -f "$dev")
    [[ $# == 0 || ( $(cat "$dev/busnum") -eq $1 && $(cat "$dev/devnum") -eq $2 ) ]] || { die 'USB 身份已变化，停止本次操作。'; return 1; }
    printf -v node '/dev/bus/usb/%03d/%03d' "$(cat "$dev/busnum")" "$(cat "$dev/devnum")"
    [[ -r $node && -w $node ]] || { usb_help; die "无权读写 $node，尚未交接 USB。"; return 1; }
    if [[ $pid == 0e8a ]]; then
        quirks=$(cat /sys/module/usb_storage/parameters/quirks 2>/dev/null || true)
        [[ ! ,$quirks, =~ ,054[cC]:0[eE]8[aA]:[^,]*i[^,]*, ]] || { die '检测到忽略相机的 usb-storage quirks；请管理员移除该项并重新插线。'; return 1; }
        intf=/sys/bus/usb/devices/${dev##*/}:1.0
        driver=$(readlink "$intf/driver" 2>/dev/null || true)
        [[ ${driver##*/} == usb-storage ]] || { die '普通身份尚未由 usb-storage 初始化，或被其他驱动占用；请重新插线。'; return 1; }
    fi
    for block in /sys/class/block/*; do
        [[ $(readlink -f "$block") == "$real/"* ]] || continue
        if mounted "$block"; then
            say "卸载相机分区 /dev/${block##*/}"
            command -v udisksctl >/dev/null && udisksctl unmount -b "/dev/${block##*/}" || {
                printf '请关闭占用程序；如需管理员权限，手动执行：sudo umount -- %q\n' "/dev/${block##*/}" >&2
                return 1
            }
        fi
    done
    for block in /sys/class/block/*; do
        [[ $(readlink -f "$block") == "$real/"* ]] || continue
        if mounted "$block"; then die '相机分区仍被挂载，请关闭自动挂载后重试。'; return 1; fi
    done
}
# Only this bridge is Python: reuse upstream USB detach and its worker/CLI entry points.
bridge() {
    "$PY" -u - "$@" <<'PY'
import os, subprocess, sys
from pathlib import Path
from desktopapp.worker import setup_runtime, execute_request
setup_runtime()
import transport
class LinuxBackend(transport.Bounded):
    def __init__(self, device, *args, **kwargs):
        super().__init__(device, *args, **kwargs)
        subprocess.run(['bash', os.environ['A7C2_SCRIPT'], '--usb-check', str(device.bus), str(device.address)], check=True)
        # Bounded.reset omits its parent's detach; do it once per new handle.
        transport.UsbBackend.reset(self)
transport.Bounded = LinuxBackend
if sys.argv[1] == '--sound-verify':
    from sound_cli import main
    raise SystemExit(main(['verify', '--workspace', sys.argv[2], '--heard-correct']))
raise SystemExit(execute_request(Path(sys.argv[1])))
PY
}
execute_bridge() {
    local access=$1; shift
    local -a runner=(bash -c 'bridge "$@"' --)
    export PY
    export -f bridge
    if [[ $access != offline ]] && command -v systemd-inhibit >/dev/null; then
        runner=(systemd-inhibit --what=sleep:idle:handle-lid-switch --why='A7C II USB operation' "${runner[@]}")
    fi
    "${runner[@]}" "$@"
}
current_work() {
    if [[ -f $CURRENT/result.private.json ]]; then jq -er .workspace "$CURRENT/result.private.json"
    else jq -er .arguments.workspace "$CURRENT/request.private.json"; fi
}
finished() {
    [[ -e $CURRENT ]] || return 0
    jq -e '.phase == "SUCCEEDED" and (.result.phase | IN("COMPLETE","COMPLETED","LOADED"))' "$CURRENT/status.private.json" >/dev/null && return 0
    if [[ $(jq -r .action "$CURRENT/request.private.json") == sound_install && -f $DATA/sound/sound.private.json ]]; then
        local job; job=$(jq -r '.boot_job // empty' "$DATA/sound/sound.private.json")
        [[ -n $job ]] && jq -e '.phase == "owner_confirmed_working"' "$job/job.private.json" >/dev/null && return 0
    fi
    return 1
}
run_job() {
    local action=$1 args=$2 access=$3 continuation=${4:-no} job rc tail_pid owner=$BASHPID
    if [[ $access == write && $continuation == no ]] && ! finished; then die '有未完成任务，请先选择继续／核对或查看原记录。'; return 1; fi
    if [[ $action == sound_install ]]; then
        "$PY" -c 'import sys; from desktopapp.actions.sound import has_conversion; sys.exit(0 if has_conversion(sys.argv[1]) else "请先转换声音。")' "$DATA/sound" || return
    fi
    if [[ $access == write ]]; then
        confirm_write "$action" "$args" || { say '已取消，返回菜单。'; return 0; }
    fi
    say "正在$(action_title "$action")…"
    args=$(jq -c --arg work "$DATA/work/$(date +%s)-$RANDOM" '. + {firmware:"2.01",power_confirmed:true} | .workspace //= $work' <<<"$args")
    job=$("$PY" -c 'import json,sys; from desktopapp.jobs import new_job; print(new_job(sys.argv[1],json.loads(sys.argv[2])))' "$action" "$args")
    [[ $access == offline || ( $access == read && $continuation == no ) ]] || ln -sfn -- "$job" "$CURRENT"
    say "日志：$job/worker.log"
    : > "$job/worker.log"
    tail -n +1 -f --pid="$owner" --sleep-interval=.1 "$job/worker.log" & tail_pid=$!
    if execute_bridge "$access" "$job/request.private.json"; then rc=0; else rc=$?; fi
    sleep .2
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
    ((rc == 0)) || { die "上游已停止；保留 $job，不自动重试写入。"; return "$rc"; }
    if [[ $access == write ]]; then
        say 'USB 读写已结束。若上方提示等待重启：拔线、正常关机、取电池至少 1 分钟，开机检查后选择 15 继续／核对。'
    elif [[ $access == read ]]; then say '本次检查已结束。'; fi
}
continue_job() {
    [[ -e $CURRENT ]] || { die '没有相机任务记录。'; return 1; }
    local action work args
    action=$(jq -r .action "$CURRENT/request.private.json"); work=$(current_work)
    yes '已按上次操作的提示完成必要的断电重开和机身检查？' || { say '已返回菜单。'; return 0; }
    case $action in
        setup_all) args=$(jq -c .arguments "$CURRENT/request.private.json"); run_job setup_all "$args" write yes ;;
        direct_factory_reset|direct_resume_factory) run_job direct_factory_reset "$(jq -cn --arg w "$work" '{failed_workspace:$w}')" write yes ;;
        restore|restore_verify) run_job restore_verify "$(jq -cn --arg w "$work" '{workspace:$w}')" read yes ;;
        sound_install)
            if yes '自定义声音内容、速度和音高正确？'; then
                execute_bridge read --sound-verify "$work" | tee -a "$CURRENT/worker.log"
            fi ;;
        direct_*)
            if jq -e '.phase | IN("AWAITING_RESOURCE_RELOAD","RESOURCE_RELOAD_VERIFIED")' "$work/direct.private.json" >/dev/null; then
                run_job direct_resume_looks "$(jq -cn --arg w "$work" '{failed_workspace:$w}')" write yes
            else run_job direct_verify "$(jq -cn --arg w "$work" '{workspace:$w}')" read yes; fi ;;
        *) die '此记录没有自动续接入口，请查看上游日志。' ;;
    esac
}
looks() {
    local rows='[]' slot file name
    while ask '目标槽位 1–6（回车结束）：' && [[ -n $REPLY ]]; do
        slot=$REPLY; [[ $slot =~ ^[1-6]$ ]] || { die '槽位必须为 1–6。'; return 1; }
        ask 'A7Look 文件路径：'; file=$(realpath -e -- "$REPLY")
        ask '名称（回车保留文件名称）：'; name=$REPLY
        rows=$(jq -c --argjson s "$slot" --arg p "$file" --arg n "$name" '. + [{slot:$s,path:$p,name:$n}]' <<<"$rows")
    done
    jq -e 'length > 0 and ([.[].slot] | length == (unique | length))' <<<"$rows" >/dev/null || { die '至少选一个槽位，且不得重复。'; return 1; }
    LOOKS=$rows
}
menu_action() {
    local choice=$1 args file output name slot options
    case $choice in
        1) run_job connect '{}' read ;; 2) run_job usb_stability '{}' read ;;
        3)
            options='{"fl23":false,"sound":false,"vertical":false,"plugin":false}'
            if yes '启用 FL2/FL3？'; then options=$(jq '.fl23=true' <<<"$options"); fi
            if yes '启用原生快门声？'; then options=$(jq '.sound=true' <<<"$options"); fi
            if yes '同时导入自己的 A7Look？'; then looks; options=$(jq --argjson rows "$LOOKS" '.looks=$rows' <<<"$options"); fi
            jq -e '.fl23 or .sound or (.looks|length)>0' <<<"$options" >/dev/null || { die '未选择功能。'; return 1; }
            run_job setup_all "$(jq -cn --argjson o "$options" '{options:$o}')" write ;;
        4) run_job direct_fl23_enable '{}' write ;; 5) run_job direct_fl23_disable '{}' write ;;
        6) looks; run_job direct_looks_import "$(jq -cn --argjson rows "$LOOKS" '{operations:$rows}')" write ;;
        7) ask '恢复 ST 的槽位 1–6（原配方无法恢复）：'; slot=$REPLY
           [[ $slot =~ ^[1-6]$ ]] || { die '槽位必须为 1–6。'; return 1; }
           run_job direct_slot_default "$(jq -cn --argjson s "$slot" '{slot:$s}')" write ;;
        8) ask 'DCP/CUBE 路径（CUBE 必须为 Sony ST/sRGB，不能是 Log LUT）：'; file=$(realpath -e -- "$REPLY")
           ask '输出 .a7look 路径：'; output=$(realpath -m -- "$REPLY"); [[ ! -e $output ]] || { die '输出已存在。'; return 1; }
           ask '外观名称：'; name=$REPLY
           run_job compile_look "$(jq -cn --arg s "$file" --arg o "$output" --arg n "$name" --arg m "$SOURCE/calibration/a7c2-2.01.virtual.npz" '{source:$s,output:$o,name:$n,model:$m}')" offline ;;
        9) run_job direct_sound_enable '{}' write ;; 10) run_job direct_sound_disable '{}' write ;; 11) run_job direct_sound_restore '{}' write ;;
        12) finished || { die '先处理未完成的相机任务。'; return 1; }
            ask '音频/视频路径：'; file=$(realpath -e -- "$REPLY")
            ask '起点秒数：'; local start=$REPLY; ask '长度秒数（0.01–2）：'
            run_job sound_import "$(jq -cn --arg s "$file" --argjson t "$start" --argjson d "$REPLY" --arg w "$DATA/sound" '{source:$s,start:$t,duration:$d,workspace:$w}')" offline ;;
        13) run_job sound_install "$(jq -cn --arg w "$DATA/sound" --arg b "$DATA/sound-backups" '{workspace:$w,backup:$b}')" write ;;
        14) run_job direct_factory_reset '{}' write ;;
        15) continue_job ;;
        16) say "记录：$DATA/runs"; [[ ! -e $CURRENT ]] || jq . "$CURRENT/status.private.json"
            if [[ -e $CURRENT ]] && yes '导出当前相机任务诊断（分享前检查路径等隐私）？'; then
                "$PY" -c 'import sys; from desktopapp.jobs import export_support; print(export_support(sys.argv[1],sys.argv[2]))' "$(readlink -f "$CURRENT")" "$BASE/diagnostics-$(date +%s).zip"
            fi ;;
        17) usb_help ;;
        18) ask '历史备份文件路径：'; file=$(realpath -e -- "$REPLY")
            args=$(jq -cn --arg b "$file" '{backup:$b}'); run_job backup_inspect "$args" offline
            run_job restore "$args" write ;;
        19) say '上游竖屏功能仍在重写，暂不开放。' ;;
        *) die '无效选项。' ;;
    esac
}
show_menu() {
    cat <<'MENU'

── 连接与安装 ──────────────────────────
  1  检查相机连接（只读）
  2  检测 USB 稳定性（只读）
  3  选择功能并安装
 15  继续上次操作 / 重启后核对

── 创意外观 ────────────────────────────
  4  启用 FL2 / FL3       5  移除 FL2 / FL3
  6  导入 A7Look         7  将槽位恢复为 ST
  8  转换 DCP / CUBE（离线）

── 快门声音 ────────────────────────────
  9  开启原生快门声     10  关闭快门声
 11  恢复原厂音效       12  转换声音（离线）
 13  安装自定义声音

── 恢复与帮助 ──────────────────────────
 14  恢复原厂功能       18  使用历史备份回退
 16  查看记录 / 导出诊断
 17  USB 权限说明       19  竖屏功能状态

  0  退出
MENU
}
self_test() {
    local temp old_current=$CURRENT
    temp=$(mktemp -d "$BASE/test.XXXXXX"); CURRENT=$temp/job; mkdir "$CURRENT"
    printf '%s\n' '{"phase":"FAILED"}' > "$CURRENT/status.private.json"
    printf '%s\n' '{"action":"direct_fl23_enable","arguments":{"workspace":"/test"}}' > "$CURRENT/request.private.json"
    if finished; then die '失败任务被当作完成'; return 1; fi
    [[ $(current_work) == /test ]]
    printf '%s\n' '{"phase":"SUCCEEDED","result":{"phase":"COMPLETED"}}' > "$CURRENT/status.private.json"
    finished
    # Redirect only the test copy of the USB guard to synthetic sysfs/mount data.
    (
        local usb=$temp/usb
        mkdir -p "$usb/sys/bus/usb/devices/1-1" "$usb/sys/class/block" "$usb/dev/bus/usb/001"
        printf 054c > "$usb/sys/bus/usb/devices/1-1/idVendor"
        printf 0e8a > "$usb/sys/bus/usb/devices/1-1/idProduct"
        printf 1 > "$usb/sys/bus/usb/devices/1-1/busnum"
        printf 2 > "$usb/sys/bus/usb/devices/1-1/devnum"
        touch "$usb/dev/bus/usb/001/002" "$usb/mountinfo"
        mkdir -p "$usb/sys/bus/usb/devices/1-1:1.0"
        ln -s /drivers/usb-storage "$usb/sys/bus/usb/devices/1-1:1.0/driver"
        eval "$(declare -f usb_prepare mounted | sed "s|/sys/|$usb/sys/|g; s|/dev/bus/usb/|$usb/dev/bus/usb/|g; s|/proc/self/mountinfo|$usb/mountinfo|g")"
        usb_prepare 1 2
        if usb_prepare 1 3 2>/dev/null; then die '身份变更未阻止'; exit 1; fi
        mkdir "$usb/sys/bus/usb/devices/1-1/block"
        printf '8:1' > "$usb/sys/bus/usb/devices/1-1/block/dev"
        ln -s "$usb/sys/bus/usb/devices/1-1/block" "$usb/sys/class/block/test-disk"
        printf '1 0 8:1 / /camera rw - vfat /dev/test-disk rw\n' > "$usb/mountinfo"
        udisksctl() { return 1; }
        if usb_prepare 1 2 2>/dev/null; then die '挂载卸载失败未阻止'; exit 1; fi
        udisksctl() { : > "$usb/mountinfo"; }
        usb_prepare 1 2
        printf 0336 > "$usb/sys/bus/usb/devices/1-1/idProduct"
        usb_prepare 1 2
        cp -r "$usb/sys/bus/usb/devices/1-1" "$usb/sys/bus/usb/devices/1-2"
        if usb_prepare 1 2 2>/dev/null; then die '多相机未阻止'; exit 1; fi
    )
    rm -rf -- "$temp"; CURRENT=$old_current
    "$PY" -m pip --isolated install --cache-dir "$BASE/pip-cache" pytest==8.3.5
    # Two integration cases assume Windows APPDATA/driver installation, outside this frontend.
    (cd "$SOURCE" && "$PY" -m pytest -q -p no:cacheprovider dev/desktop/test_allinone.py dev/desktop/test_direct.py dev/desktop/test_integration.py \
        -k 'not frozen_plugin_installs and not unknown_sony_pid_is_reported')
}
main() {
    case ${1:-menu} in help|--help|-h) help_text; return ;; usb-help) usb_help; return ;; --usb-check) shift; usb_prepare "$@"; return ;; esac
    [[ $(uname -s) == Linux && $EUID != 0 ]] || { die '请用 Linux 普通用户运行。'; return 1; }
    mkdir -p "$BASE"; exec 9>"$BASE/launcher.lock"; flock -n 9 || { die '另一个实例正在运行。'; return 1; }
    setup
    case ${1:-menu} in
        setup|--prepare) say "准备完成：$SOURCE" ;;
        doctor|--doctor) cat "$BASE/doctor.json" ;;
        test|--self-test) self_test ;;
        status) [[ ! -e $CURRENT ]] || jq . "$CURRENT/status.private.json" ;;
        continue) continue_job ;;
        menu)
            [[ -t 0 ]] || { die '菜单需要终端。'; return 1; }
            say 'A7C II Linux · 仅支持 ILCE-7CM2 / 固件 2.01'
            say '相机设为海量存储并连接 USB，输入 1 即可检查连接。'
            say '已在 Fedora 44 + A7C II 2.01 实机验证；写入功能会在执行前单独确认。'
            while true; do
                show_menu
                ask '输入编号：'; [[ $REPLY != 0 ]] || break
                # Subshell keeps errexit active inside actions; errors return to the menu.
                set +e
                (set -e; menu_action "$REPLY")
                local rc=$?
                set -e
                ((rc == 0)) || say '未完成，已返回菜单；原因见上方提示。'
            done ;;
        *) help_text; return 2 ;;
    esac
}
main "$@"
