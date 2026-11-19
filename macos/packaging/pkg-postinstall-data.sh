#!/bin/bash
# Gogaku 数据包 pkg postinstall（用户级，不提权）。
#
# 与代码包 postinstall 同一套事务骨架（备份→替换→失败恢复→transaction.txt），
# 但替换对象是两个 App 的 Contents/Resources/EngineData：
# - 逐文件 SHA-256 校验（清单 @DATA_MANIFEST@，随 Scripts 注入）；
# - 数据指纹 @DATA_FINGERPRINT@ 写入收据目录，供诊断；
# - 输入法运行中的旧进程持有旧 inode，继续用旧数据打字直到优雅退出
#   （代码包安装器会发 org.gogaku.inputmethod.restart）；新进程读新数据。
# 系统 Installer 路径下的数据包只服务老式手动安装；客户端就地更新走
# UpdateInstaller.installData（同一份清单格式）。
set -uo pipefail

HOME_DIR="${HOME:-/Users/$(id -un)}"
IM_DIR="$HOME_DIR/Library/Input Methods"
APPS_DIR="$HOME_DIR/Applications"
INPUT_APP="@INPUT_APP@"
SETTINGS_APP="@SETTINGS_APP@"
STATE_DIR="$HOME_DIR/Library/Application Support/Gogaku/install"
BACKUP_ROOT="$STATE_DIR/backups"
STATE="$STATE_DIR/transaction.txt"
EXPECTED_BUILD="@BUILD@"
DATA_VERSION="@DATA_VERSION@"
BACKUP=""
INSTALLED=0

data_manifest="@DATA_MANIFEST@"

target_for() {
    case "$1" in
        input) echo "$IM_DIR/$INPUT_APP" ;;
        settings) echo "$APPS_DIR/$SETTINGS_APP" ;;
    esac
}
backup_for() { echo "$BACKUP/$1.disabled"; }

write_state() {
    mkdir -p "$STATE_DIR"
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
    echo "数据安装失败：$1" >&2
    restore
    write_state failed
    echo "已恢复安装前的 EngineData（若存在）。" >&2
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
    echo "检测到未完成的数据安装事务；先恢复上一份数据。"
    for role in input settings; do
        target="$(target_for "$role")"
        old="$old_backup/$role.disabled"
        if [ -e "$old" ]; then
            rm -rf "$target"
            mv "$old" "$target" 2>/dev/null || true
        fi
    done
}

engine_data_of() { echo "$1/Contents/Resources/EngineData"; }

hash_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

STAGE="$(mktemp -d "$HOME_DIR/Library/Caches/Gogaku/data-stage.XXXXXX" 2>/dev/null || mktemp -d)"
recover_incomplete
mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
BACKUP="$(mktemp -d "$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")"
write_state installing

ditto -x -k "$SCRIPT_DIR/Gogaku-data.zip" "$STAGE" || fail "无法解包数据内容"
[ -f "$STAGE/manifest.json" ] || fail "数据内容缺少 manifest.json"

# 清单校验：schema、dataVersion 与指纹自洽、条目路径安全。
python3 - "$STAGE/manifest.json" <<'PY' || fail "数据清单非法"
import hashlib, json, sys
manifest = json.load(open(sys.argv[1]))
assert manifest.get('schema') == 1, 'schema'
version = manifest.get('dataVersion') or ''
files = manifest.get('files') or []
assert files, 'empty'
joined = '\n'.join(f"{e['path']}:{e['sha256']}" for e in sorted(files, key=lambda e: e['path']))
fingerprint = hashlib.sha256(joined.encode()).hexdigest()[:16]
assert version == fingerprint, 'dataVersion mismatch'
for e in files:
    p = e['path']
    assert p and not p.startswith('/') and '..' not in p.split('/') and '\\' not in p, p
    assert len(e['sha256']) == 64, p
print('manifest ok', version)
PY

# 逐文件哈希（先完整校验，再动任何目标）。
while IFS= read -r line; do
    rel="${line%%:*}"
    expected="${line#*:}"
    file="$STAGE/$rel"
    [ -f "$file" ] || fail "数据包缺少 $rel"
    actual="$(hash_file "$file")"
    [ "$actual" = "$expected" ] || fail "数据文件哈希不符：$rel"
done <<EOF
$(python3 -c "
import json, sys
for e in json.load(open(sys.argv[1]))['files']:
    print(f\"{e['path']}:{e['sha256']}\")
" "$STAGE/manifest.json")
EOF

# 数据只落到真实安装的双 App；缺任一目标说明代码尚未安装。
for role in input settings; do
    target="$(target_for "$role")"
    [ -d "$target/Contents" ] || fail "未找到已安装的 $(basename "$target")；请先安装代码包"
done

for role in input settings; do
    target="$(engine_data_of "$(target_for "$role")")"
    if [ -d "$target" ]; then
        ditto "$target" "$(backup_for "$role")" || fail "备份 $role 数据失败"
        [ -f "$(backup_for "$role")/$(ls "$(backup_for "$role")" | head -1)" ] || fail "备份 $role 不完整"
    fi
done

for role in input settings; do
    target="$(engine_data_of "$(target_for "$role")")"
    mkdir -p "$(dirname "$target")"
    rm -rf "$target"
    while IFS= read -r rel; do
        mkdir -p "$target/$(dirname "$rel")"
        cp "$STAGE/$rel" "$target/$rel" || fail "写入 $role 数据失败：$rel"
    done <<EOF
$(python3 -c "
import json, sys
for e in json.load(open(sys.argv[1]))['files']:
    print(e['path'])
" "$STAGE/manifest.json")
EOF
    INSTALLED=1
done

# 安装后抽验首尾条目（与 pre 校验同一份清单）。
for role in input settings; do
    target="$(engine_data_of "$(target_for "$role")")"
    while IFS= read -r line; do
        rel="${line%%:*}"; expected="${line#*:}"
        actual="$(hash_file "$target/$rel")"
        [ "$actual" = "$expected" ] || fail "安装后哈希不符：$role/$rel"
    done <<EOF
$(python3 -c "
import json, sys
for e in json.load(open(sys.argv[1]))['files']:
    print(f\"{e['path']}:{e['sha256']}\")
" "$STAGE/manifest.json")
EOF
done

mkdir -p "$STATE_DIR"
printf '%s\n' "$DATA_VERSION" > "$STATE_DIR/last-data-version.txt"
write_state success

ls -1dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +3 | while read -r old; do
    [ -n "$old" ] && rm -rf "$old"
done

echo "Gogaku 数据已更新：$DATA_VERSION"
exit 0
