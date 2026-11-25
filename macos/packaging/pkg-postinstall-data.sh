#!/bin/bash
# Gogaku 数据包 pkg postinstall（用户级，不提权）。
#
# 仅替换两 App 的 EngineData，事务与代码安装、其他通道和形态隔离。
# 校验表与内层 JSON 清单由构包器从同一份数据生成；安装不依赖 Python/Xcode。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

HOME_DIR="${HOME:-/Users/$(id -un)}"
IM_DIR="$HOME_DIR/Library/Input Methods"
APPS_DIR="$HOME_DIR/Applications"
INPUT_APP="@INPUT_APP@"
SETTINGS_APP="@SETTINGS_APP@"
STATE_DIR="$HOME_DIR/Library/Application Support/Gogaku/install"
DATA_STATE_DIR="$STATE_DIR/data-@INPUT_ID@"
BACKUP_ROOT="$DATA_STATE_DIR/backups"
STATE="$DATA_STATE_DIR/transaction.txt"
EXPECTED_BUILD="@BUILD@"
DATA_VERSION="@DATA_VERSION@"
BACKUP=""
STAGE=""

target_for() {
    case "$1" in
        input) echo "$IM_DIR/$INPUT_APP" ;;
        settings) echo "$APPS_DIR/$SETTINGS_APP" ;;
    esac
}
engine_data_for() { printf '%s/Contents/Resources/EngineData\n' "$(target_for "$1")"; }

write_state() {
    local tmp="$STATE.tmp"
    {
        echo "phase=$1"
        echo "build=$EXPECTED_BUILD"
        echo "dataVersion=$DATA_VERSION"
        echo "backup=$BACKUP"
        echo "updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$tmp" && mv "$tmp" "$STATE"
}

restore() {
    local backup="$1" role target old
    for role in input settings; do
        target="$(engine_data_for "$role")"
        old="$backup/$role.disabled"
        if [ -e "$old" ]; then
            rm -rf "$target" && mv "$old" "$target" || return 1
        elif [ -f "$backup/$role.absent" ]; then
            rm -rf "$target" || return 1
        fi
    done
}

fail() {
    echo "数据安装失败：$1" >&2
    if [ -n "$BACKUP" ]; then
        if restore "$BACKUP"; then
            write_state failed
            echo "已恢复安装前的 EngineData。" >&2
        else
            echo "数据备份仍在，重试安装前将再次尝试恢复。" >&2
        fi
    fi
    exit 1
}

cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; }
trap cleanup EXIT

read_state_value() {
    [ -f "$STATE" ] || return 0
    sed -n "s/^$1=//p" "$STATE" | head -1
}

recover_incomplete() {
    local phase old_backup
    phase="$(read_state_value phase)"
    old_backup="$(read_state_value backup)"
    [ "$phase" = "installing" ] || return 0
    [ -n "$old_backup" ] && [ -d "$old_backup" ] || return 0
    echo "检测到未完成的数据安装事务；先恢复上一份数据。"
    restore "$old_backup" || fail "无法恢复上一份数据"
}

hash_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# 数据只落到真实安装的双 App；缺任一目标说明代码尚未安装。
for role in input settings; do
    target="$(target_for "$role")"
    [ -d "$target/Contents" ] || fail "未找到已安装的 $(basename "$target")；请先安装代码包"
done

recover_incomplete
STAGE="$(mktemp -d "$HOME_DIR/Library/Caches/Gogaku/data-stage.XXXXXX" 2>/dev/null || mktemp -d)" \
    || fail "无法建立数据暂存目录"
ditto -x -k "$SCRIPT_DIR/Gogaku-data.zip" "$STAGE/unpacked" || fail "无法解包数据内容"
[ "$(hash_file "$STAGE/unpacked/manifest.json")" = "@MANIFEST_SHA256@" ] || fail "数据清单不符"

# 在替换任何已安装数据之前，暂存并校验构包时列出的全部文件。
while read -r expected rel; do
    source="$STAGE/unpacked/$rel"
    destination="$STAGE/EngineData/$rel"
    [ -f "$source" ] && [ "$(hash_file "$source")" = "$expected" ] || fail "数据文件哈希不符：$rel"
    mkdir -p "$(dirname "$destination")" && cp "$source" "$destination" || fail "暂存数据失败：$rel"
done <<'CHECKSUMS'
@DATA_CHECKSUMS@
CHECKSUMS
printf '%s\n' "$DATA_VERSION" > "$STAGE/EngineData/.gogaku-data-version" || fail "无法写入版本标记"

mkdir -p "$BACKUP_ROOT" || fail "无法建立数据备份目录"
BACKUP="$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")" || fail "无法建立数据备份"
write_state installing || fail "无法记录数据安装事务"
for role in input settings; do
    target="$(engine_data_for "$role")"
    if [ -e "$target" ]; then
        mv "$target" "$BACKUP/$role.disabled" || fail "备份 $role 数据失败"
    else
        touch "$BACKUP/$role.absent" || fail "记录 $role 的原始数据状态失败"
    fi
    ditto "$STAGE/EngineData" "$target" || fail "写入 $role 数据失败"
done

write_state success || fail "无法记录数据安装结果"
printf '%s\n' "$DATA_VERSION" > "$STATE_DIR/last-data-version.txt" || echo "无法写入数据诊断收据" >&2

ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +3 | while read -r old; do
    [ -n "$old" ] && rm -rf "$old"
done

echo "Gogaku 数据已更新：$DATA_VERSION"
exit 0
