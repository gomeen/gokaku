#!/usr/bin/env bash
# macOS 上交叉构建 Gogaku 共享核心（Windows x64）＋自检包。
#
# 与 VM／CI（windows-core workflow）的差别：在 Mac 上用 Homebrew mingw-w64
# GCC 交叉编译，不用 MSYS2；依赖垫片（dlfcn/gettext/libiconv/zstd/zlib）直接
# 解包 MSYS2 clang64 包到本地 sysroot，.pc 路径改写为本机绝对路径。
# libime 源码应用 scripts/patches/libime-win-cross.patch（Boost iostreams
# 条件化——MinGW GCC libstdc++ 保留 std::binary_function，无需 kenlm 补丁）。
#
# 核心（shared/GogakuCore）从隔离副本构建：副本注入两项 Windows 兼容
# 修正（见下），不触碰共享工作区（可能存在并行会话的未提交 WIP）。
# 这两项修正待共享核心的活跃改动合入后应上游化进 git，本脚本的自检
# （grep）会跳过已含修正的副本。
#
#   1) fsync → _commit（MinGW 无 fsync；MSVCRT _commit 等价）
#   2) CMakeLists WIN32 输出目录自引用修正（DLL 与测试 exe 同目录）
#
# 产物：.build/win-cross/core-build/bin/（DLL＋测试 exe）
#       local/selfcheck/gogaku-core-selfcheck.zip（自检包）
# 验证记录：macOS 26.7.2 + mingw-w64 14.0.0(GCC 16.2) 全流程通过，
#   自检包于 Windows 11 VM 全绿（docs/validation/win-core-selfcheck/）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WC=$ROOT/.build/win-cross
NINJA=$(which ninja)
LIBIME_COMMIT=5be1300ea00e899b3f2c46d1e9f6bca21139cdeb
FCITX_COMMIT=dfb1278cce616a771eb51a99a468bbd69f02613f
ECM_COMMIT=7dd28cc56c339c3f8fb356f7c53c0e8f61433d81
export PKG_CONFIG_PATH=$WC/msys-sysroot/clang64/lib/pkgconfig

for tool in ninja pkg-config x86_64-w64-mingw32-g++; do
  command -v $tool >/dev/null || { echo "缺少 $tool（brew install mingw-w64 / ninja）"; exit 1; }
done

# ── 源码（同 pin）──────────────────────────────────────────────
mkdir -p $WC/deps
cd $WC/deps
for repo in "https://github.com/fcitx/libime.git libime $LIBIME_COMMIT" \
            "https://github.com/fcitx/fcitx5.git fcitx5 $FCITX_COMMIT" \
            "https://github.com/KDE/extra-cmake-modules.git ecm $ECM_COMMIT"; do
  set -- $repo
  [ -d "$2/.git" ] || git init -q "$2"
  git -C "$2" remote add origin "$1" 2>/dev/null || true
  git -C "$2" fetch -q --depth 1 origin "$3"
  git -C "$2" checkout -q --detach "$3"
done
cd libime
git apply --check $ROOT/scripts/patches/libime-win-cross.patch 2>/dev/null &&
  git apply $ROOT/scripts/patches/libime-win-cross.patch &&
  echo "libime patch applied" || echo "libime patch already applied"
cd ..

# ── MSYS2 垫片 sysroot（dlfcn/gettext/libiconv/zstd/zlib）──────
mkdir -p $WC/msys-sysroot
cd $WC/msys-sysroot
for pkg in dlfcn gettext-runtime libiconv zstd zlib; do
  name=$(curl -sL "https://repo.msys2.org/mingw/clang64/" |
         grep -oE "mingw-w64-clang-x86_64-$pkg-[0-9][^\"]*\\.pkg\\.tar\\.zst" | sort -uV | tail -1)
  [ -f "$name" ] || curl -sL -o "$name" "https://repo.msys2.org/mingw/clang64/$name"
  tar --zstd -xf "$name" -C .
done
# .pc 路径改写为本机绝对路径（MSYS2 包内是 /clang64 布局）
REAL=$(cd clang64 && pwd)
for pc in clang64/lib/pkgconfig/*.pc; do
  sed -i '' "s|^prefix=.*|prefix=$REAL|; s|^exec_prefix=.*|exec_prefix=$REAL|; \
             s|^libdir=.*|libdir=$REAL/lib|; s|^includedir=.*|includedir=$REAL/include|; \
             s|^sharedlibdir=.*|sharedlibdir=$REAL/bin|" "$pc"
done

# ── 工具链文件 ────────────────────────────────────────────────
cd $ROOT
cat > $WC/toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)
set(MINGW_TOOLCHAIN /usr/local/opt/mingw-w64/toolchain-x86_64)
set(CMAKE_C_COMPILER \${MINGW_TOOLCHAIN}/bin/x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER \${MINGW_TOOLCHAIN}/bin/x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER \${MINGW_TOOLCHAIN}/bin/x86_64-w64-mingw32-windres)
set(CMAKE_AR \${MINGW_TOOLCHAIN}/bin/x86_64-w64-mingw32-ar CACHE FILEPATH "")
set(CMAKE_RANLIB \${MINGW_TOOLCHAIN}/bin/x86_64-w64-mingw32-ranlib CACHE FILEPATH "")
# 只静态链接 GCC 运行时；exe 动态依赖自带的 libIME*/Fcitx5Utils DLL。
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++ -L$WC/msys-sysroot/clang64/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++ -L$WC/msys-sysroot/clang64/lib")
set(CMAKE_FIND_ROOT_PATH \${MINGW_TOOLCHAIN}/x86_64-w64-mingw32 /usr/local/opt/boost $WC/msys-sysroot/clang64 $WC/prefix)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# ── ECM → Fcitx5Utils → libime ────────────────────────────────
cmake -S $WC/deps/ecm -B $WC/ecm-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$WC/toolchain.cmake -DCMAKE_INSTALL_PREFIX=$WC/prefix \
  -DBUILD_TESTING=OFF -DBUILD_DOC=OFF >/dev/null
cmake --build $WC/ecm-build -j 8 >/dev/null
cmake --install $WC/ecm-build >/dev/null

FCITX_OPTS=(-DENABLE_TEST=OFF -DENABLE_TESTING_ADDONS=OFF -DENABLE_X11=OFF
  -DENABLE_WAYLAND=OFF -DENABLE_DBUS=OFF -DENABLE_ENCHANT=OFF -DENABLE_SERVER=OFF
  -DENABLE_KEYBOARD=OFF -DENABLE_EMOJI=OFF -DENABLE_LIBUUID=OFF
  -DBUILD_SPELL_DICT=OFF -DENABLE_XDGAUTOSTART=OFF -DEVENT_LOOP_BACKEND=none)
cmake -S $WC/deps/fcitx5 -B $WC/fcitx5-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$WC/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$WC/prefix -DCMAKE_PREFIX_PATH=$WC/prefix "${FCITX_OPTS[@]}" >/dev/null
cmake --build $WC/fcitx5-build --target Fcitx5Utils -j 8 >/dev/null
cmake --install $WC/fcitx5-build/src/lib/fcitx-utils >/dev/null

LIBIME_OPTS=(-DENABLE_TEST=OFF -DENABLE_DATA=OFF -DENABLE_DOC=OFF -DENABLE_TOOLS=ON
  -DCMAKE_CXX_FLAGS=-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION)
cmake -S $WC/deps/libime -B $WC/libime-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$WC/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$WC/prefix -DCMAKE_PREFIX_PATH=$WC/prefix "${LIBIME_OPTS[@]}" >/dev/null
cmake --build $WC/libime-build --target IMEPinyin libime_pinyindict libime_slm_build_binary -j 8 >/dev/null
cmake --install $WC/libime-build >/dev/null 2>&1 || true  # table 组件安装失败可忽略（未构建）

# ── GogakuCore（隔离副本＋Windows 兼容注入）────────────────────
mkdir -p $WC/deps-root $WC/core-src
ln -sfn $WC/deps/libime $WC/deps-root/source
ln -sfn $WC/libime-build $WC/deps-root/build
ln -sfn $WC/prefix $WC/deps-root/prefix
rsync -a --delete $ROOT/shared/GogakuCore/ $WC/core-src/ --exclude '*.o' --exclude 'bin'
# 共享第三方向量要跟着核心走：core-src/../third_party 是 CMake 的 include 路径。
rsync -a --delete $ROOT/shared/third_party/ $WC/third_party/
# 注入 1：fsync → _commit（MinGW；open/close/chmod 经 oldnames 可用）。
python3 - "$WC/core-src" <<'PYEOF'
import re, sys
root = sys.argv[1]
block = ('#ifdef _WIN32\n'
         '/* MinGW 无 fsync；MSVCRT 的 _commit 等价（落盘到磁盘）。*/\n'
         '#define fsync _commit\n#endif\n')
for name in ['custom_words.cpp', 'normal_session.cpp']:
    p = f'{root}/{name}'
    s = open(p).read()
    if '#define fsync _commit' in s:
        continue
    s = s.replace('#include <unistd.h>\n', '#include <unistd.h>\n\n' + block, 1)
    open(p, 'w').write(s)
    print(f'fsync compat injected: {name}')
# 注入 2：WIN32 输出目录自引用修正（DLL 与测试 exe 同目录）。
p = f'{root}/CMakeLists.txt'
s = open(p).read()
if 'RUNTIME_OUTPUT_DIRECTORY $<TARGET_FILE_DIR:GogakuCore>' in s:
    broken = ('if(WIN32)\n'
              '  set_target_properties(GogakuCore PROPERTIES RUNTIME_OUTPUT_DIRECTORY '
              '$<TARGET_FILE_DIR:GogakuCore>)\nendif()\n')
    fixed = ('if(WIN32)\n'
             '  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/bin)\n'
             'endif()\n\n')
    s = s.replace(broken, '')
    s = s.replace('add_library(GogakuCore SHARED', fixed + 'add_library(GogakuCore SHARED', 1)
    open(p, 'w').write(s)
    print('WIN32 output-dir fix injected: CMakeLists.txt')
PYEOF

mkdir -p $WC/deps-root
rm -rf $WC/core-build
BOOST_INCLUDE=/usr/local/opt/boost/include \
cmake -S $WC/core-src -B $WC/core-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$WC/toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
  -DGOGAKU_DEPS=$WC/deps-root >/dev/null
cmake --build $WC/core-build -j 8

echo "交叉构建完成：$WC/core-build/bin/"
python3 scripts/package-win-selfcheck.py
