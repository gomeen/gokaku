#!/bin/bash
# Gogaku pkg postinstall（用户级，不提权）。
#
# 事务式安装：先完整解包＋校验双 App，备份旧包，再替换；任一步失败恢复两者。
# 事务状态留在用户目录，下次安装／manage-install recover 可先恢复被中断的安装。
# 不先删除唯一可用副本，不强杀宿主，不联网。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${HOME:-/Users/$(id -un)}"
IM_DIR="$HOME_DIR/Library/Input Methods"
APPS_DIR="$HOME_DIR/Applications"
INPUT_APP="@INPUT_APP@"
SETTINGS_APP="@SETTINGS_APP@"
INPUT_ID="@INPUT_ID@"
SETTINGS_ID="@SETTINGS_ID@"
EXPECTED_BUILD="@BUILD@"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
STATE_DIR="$HOME_DIR/Library/Application Support/Gogaku/install"
BACKUP_ROOT="$STATE_DIR/backups"
STATE="$STATE_DIR/transaction.txt"
BACKUP=""
STAGE=""
INSTALLED=0

target_for() {
    case "$1" in
        input) echo "$IM_DIR/$INPUT_APP" ;;
        settings) echo "$APPS_DIR/$SETTINGS_APP" ;;
    esac
}
backup_for() { echo "$BACKUP/$1.disabled"; }
name_for() {
    case "$1" in
        input) echo "$INPUT_APP" ;;
        settings) echo "$SETTINGS_APP" ;;
    esac
}
identifier_for() {
    case "$1" in
        input) echo "$INPUT_ID" ;;
        settings) echo "$SETTINGS_ID" ;;
    esac
}
bundle_for() {
    case "$1" in
        input) echo "$STAGE/$INPUT_APP" ;;
        settings) echo "$STAGE/$SETTINGS_APP" ;;
    esac
}

write_state() {
    mkdir -p "$STATE_DIR"
    local tmp="$STATE.tmp"
    {
        echo "phase=$1"
        echo "build=$EXPECTED_BUILD"
        echo "backup=$BACKUP"
        echo "updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$tmp" && mv "$tmp" "$STATE"
}

restore() {
    local role target old
    for role in input settings; do
        target="$(target_for "$role")"
        old="$(backup_for "$role")"
        if [ -e "$old" ]; then
            rm -rf "$target"
            mv "$old" "$target" 2>/dev/null || true
        elif [ "$INSTALLED" -eq 1 ]; then
            rm -rf "$target"
        fi
    done
}

fail() {
    echo "安装失败：$1" >&2
    restore
    write_state failed
    echo "已恢复安装前的应用（若存在）；用户数据未修改。" >&2
    exit 1
}

cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; }
trap cleanup EXIT

read_state_value() {
    [ -f "$STATE" ] || return 0
    sed -n "s/^$1=//p" "$STATE" | head -1
}

recover_incomplete() {
    local phase old_backup role target old
    phase="$(read_state_value phase)"
    old_backup="$(read_state_value backup)"
    [ "$phase" = "success" ] && return 0
    [ -n "$old_backup" ] && [ -d "$old_backup" ] || return 0
    echo "检测到未完成的安装事务；先恢复上一版本。"
    for role in input settings; do
        target="$(target_for "$role")"
        old="$old_backup/$role.disabled"
        if [ -e "$old" ]; then
            rm -rf "$target"
            mv "$old" "$target" 2>/dev/null || true
        fi
    done
}

recover_incomplete
mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
BACKUP="$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
write_state installing

STAGE="$(mktemp -d "$HOME_DIR/Library/Caches/Gogaku/pkg-stage.XXXXXX" 2>/dev/null || mktemp -d)"
ditto -x -k "$SCRIPT_DIR/Gogaku-apps.zip" "$STAGE" || fail "无法解包安装内容"

for role in input settings; do
    bundle="$(bundle_for "$role")"
    [ -d "$bundle" ] || fail "安装内容缺少 $(name_for "$role")"
    plist="$bundle/Contents/Info.plist"
    [ -f "$plist" ] || fail "$(name_for "$role") 缺少 Info.plist"
    actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    [ "$actual_id" = "$(identifier_for "$role")" ] || fail "$(name_for "$role") 身份不符：$actual_id"
    actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
    [ "$actual_build" = "$EXPECTED_BUILD" ] || fail "$(name_for "$role") 构建号不符：$actual_build ≠ $EXPECTED_BUILD"
    # 身份与签名已在打包阶段完成；安装时不重签，保留 Developer ID 签名与公证。
    if [ "$role" = "input" ]; then
        actual_tis="$(/usr/libexec/PlistBuddy -c 'Print :TISInputSourceID' "$plist" 2>/dev/null || true)"
        [ "$actual_tis" = "$INPUT_ID" ] || fail "输入法身份键不符：$actual_tis ≠ $INPUT_ID"
    fi
    codesign --verify --deep --strict "$bundle" >/dev/null 2>&1 || fail "$(name_for "$role") 签名校验失败"
done

# 备份旧包（复制，不移动；安装失败时恢复）。
for role in input settings; do
    target="$(target_for "$role")"
    if [ -e "$target" ]; then
        ditto "$target" "$(backup_for "$role")" || fail "备份 $(name_for "$role") 失败"
        [ -f "$(backup_for "$role")/Contents/Info.plist" ] || fail "备份 $(name_for "$role") 不完整"
    fi
done

mkdir -p "$IM_DIR" "$APPS_DIR"
for role in input settings; do
    target="$(target_for "$role")"
    rm -rf "$target"
    mv "$(bundle_for "$role")" "$target" || fail "无法放入 $(name_for "$role")"
    INSTALLED=1
done

codesign --verify --deep --strict "$IM_DIR/$INPUT_APP" >/dev/null 2>&1 || fail "输入法签名校验失败"
codesign --verify --deep --strict "$APPS_DIR/$SETTINGS_APP" >/dev/null 2>&1 || fail "设置应用签名校验失败"

for role in input settings; do
    target="$(target_for "$role")"
    plist="$target/Contents/Info.plist"
    actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    [ "$actual_id" = "$(identifier_for "$role")" ] || fail "安装后身份不符：$actual_id"
    actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
    [ "$actual_build" = "$EXPECTED_BUILD" ] || fail "安装后构建号不符：$actual_build"
done

"$LSREGISTER" -f "$IM_DIR/$INPUT_APP" >/dev/null 2>&1 || true
write_state success

# 保留最近两份安装前备份（.disabled 后缀避免 LaunchServices 误启动）。
ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +3 | while read -r old; do
    [ -n "$old" ] && rm -rf "$old"
done

if defaults read com.apple.HIToolbox AppleSelectedInputSources 2>/dev/null | grep -q "$INPUT_ID"; then
    echo "提示：当前输入源是 Gogaku。安装已完成；请切换一次输入源或重新登录以加载新版本。"
fi
if pgrep -f "$IM_DIR/$INPUT_APP/Contents/MacOS/" >/dev/null 2>&1; then
    echo "提示：旧 Gogaku 进程仍在运行（不会强杀）；切换输入源或注销后加载新版本。"
fi
echo "Gogaku 已安装：$IM_DIR/$INPUT_APP"
exit 0
