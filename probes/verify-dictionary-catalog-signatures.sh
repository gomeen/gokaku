#!/bin/bash
# 用已构建的 Swift Release 模块及 Windows x64 对象离线核对渠道签名。
set -euo pipefail
cd "$(dirname "$0")/.."
win="${1:-.build/dict-0.5-validation/win-full}"
out=.build/dictionary-catalog-selfcheck
mkdir -p "$out"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export GOGAKU_BUILD_ROOT="$PWD/.build"
swift_bin=$(swift build --package-path macos -c release --show-bin-path)
vectors="$PWD/probes/dictionary-catalog-vectors.json"

swiftc -parse-as-library probes/dictionary-catalog-selfcheck.swift \
  -I "$swift_bin/Modules" -I macos/Sources/CGogakuCore -I macos/Sources/CGogakuEngine -I macos/Sources/CSQLite \
  -L .build/core -lgogaku_core -L .build/native -lGogakuEngine -lsqlite3 \
  -Xlinker -rpath -Xlinker "$PWD/.build/core" -Xlinker -rpath -Xlinker "$PWD/.build/native" \
  "$swift_bin"/GogakuKit.build/*.o -o "$out/dictionary-catalog-selfcheck"
"$out/dictionary-catalog-selfcheck" "$vectors" > "$out/macos.log"

x86_64-w64-mingw32-g++ -std=c++20 -O2 -static -municode \
  probes/dictionary-catalog-selfcheck.cpp \
  "$win/obj64/"{dictionaries,platform,settings_contract,monocypher,monocypher-ed25519}.o \
  -ladvapi32 -lbcrypt -lcrypt32 -lole32 -lshell32 -luuid -o "$out/dictionary-catalog-selfcheck.exe"
if [[ $# -lt 2 ]]; then
  printf 'Mac 验证结果 %s，Windows 自检已编译至 %s\n' "$out/macos.log" "$out/dictionary-catalog-selfcheck.exe"
  exit 0
fi

# 可选 Wine 仅运行离线控制台自检。两边输出须完全一致。
wine="${2:?传入 Wine 路径}"
export MVK_CONFIG_LOG_LEVEL=0
export WINEDEBUG=-all
export WINEPREFIX="${WINEPREFIX:-$PWD/.build/win-tools/prefix}"
for candidate in "$out/dictionary-catalog-selfcheck.exe" "$vectors" "$win/bin/x64/libgogaku_core.dll"; do
  [[ -f "$candidate" ]]
done
windows_path() {
  local absolute
  absolute=$(cd "$(dirname "$1")" && printf '%s/%s' "$PWD" "$(basename "$1")")
  printf 'Z:%s' "${absolute//\//\\}"
}
"$wine" "$(windows_path "$out/dictionary-catalog-selfcheck.exe")" "$(windows_path "$vectors")" \
  "$(windows_path "$win/bin/x64/libgogaku_core.dll")" > "$out/windows.log"
tr -d '\r' < "$out/windows.log" > "$out/windows-normalized.log"
diff -u "$out/macos.log" "$out/windows-normalized.log"
