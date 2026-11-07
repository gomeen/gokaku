#!/usr/bin/env bash
# 构建单文件版 Windows 自检程序：gogaku-selfcheck.exe
#
# 与 prepare-win-cross.sh（DLL 版自检包）的差异：
# - 全静态链接：Fcitx5Utils／IMECore／IMEPinyin／GogakuCore 全部为静态库，
#   zlib/zstd/intl/iconv/dl 用 sysroot 静态库，GCC 运行时亦静态——
#   产物零 DLL 依赖，朋友只需拿走一个 exe。
# - 六个测试程序的 main 用 -Dmain=test_main_<名> 改名后与一个 runner 合链：
#   runner 启动时把内嵌的出厂数据（sc.dict／zh_CN.lm，objcopy 嵌入）解压到
#   %TEMP%，设置 GOGAKU_CORE_TEST_DATA，顺序运行全部测试并汇总一行结论，
#   结尾「按回车退出」保证双击运行时窗口不闪退。
# - Windows 路径适配注入：测试的 mkdtemp 模板从 /tmp 改为 %TEMP%（Windows
#   无 /tmp，否则数据相关测试静默 SKIP）。
#
# 产物：local/selfcheck/gogaku-selfcheck.exe（单文件，约 50MB）
# 验证：Windows 11 VM 内六项全过（见 docs/validation/win-core-selfcheck/）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WC=$ROOT/.build/win-cross
SC=$WC/static
MINGW_TOOLCHAIN=/usr/local/opt/mingw-w64/toolchain-x86_64
NINJA=$(which ninja)
LIBIME_COMMIT=5be1300ea00e899b3f2c46d1e9f6bca21139cdeb
FCITX_COMMIT=dfb1278cce616a771eb51a99a468bbd69f02613f
ECM_COMMIT=7dd28cc56c339c3f8fb356f7c53c0e8f61433d81
CC=$MINGW_TOOLCHAIN/bin/x86_64-w64-mingw32-gcc
CXX=$MINGW_TOOLCHAIN/bin/x86_64-w64-mingw32-g++
OBJCOPY=$MINGW_TOOLCHAIN/bin/x86_64-w64-mingw32-objcopy
export PKG_CONFIG_PATH=$WC/msys-sysroot/clang64/lib/pkgconfig

for tool in ninja pkg-config "$CC" "$CXX" "$OBJCOPY"; do
  [ -x "$tool" ] || command -v $tool >/dev/null || { echo "缺少 $tool（先跑 scripts/prepare-win-cross.sh 安装 mingw-w64）"; exit 1; }
done

# ── 独立源码树（与 DLL 版的 deps 共享 pin；静态化补丁不回流共享树）──
mkdir -p $SC
cd $SC
if [ ! -d libime/.git ]; then
  cp -a $WC/deps/libime libime
  cp -a $WC/deps/fcitx5 fcitx5
  cp -a $WC/deps/ecm ecm
fi
# 同步补丁基线：libime 已含 iostreams 补丁（deps 树带出）。

# ── MSYS2 垫片 sysroot（复用 DLL 版；缺则重建）──────────────────
if [ ! -f $WC/msys-sysroot/clang64/include/zstd.h ]; then
  echo "sysroot 缺失：先跑 scripts/prepare-win-cross.sh"; exit 1
fi
REAL=$WC/msys-sysroot/clang64
for pc in $WC/msys-sysroot/clang64/lib/pkgconfig/*.pc; do
  grep -q "prefix=$REAL" "$pc" || sed -i '' "s|^prefix=.*|prefix=$REAL|; s|^exec_prefix=.*|exec_prefix=$REAL|; s|^libdir=.*|libdir=$REAL/lib|; s|^includedir=.*|includedir=$REAL/include|; s|^sharedlibdir=.*|sharedlibdir=$REAL/bin|" "$pc"
done

# 消费者前置定义：静态导出的 Fcitx5::Utils 在接口里引用
# DL::DL／LibIntl::LibIntl／Pthread::Pthread（SHARED 版不带），消费前须存在。
cat > $SC/consumer-prelude.cmake <<'PRELUDE'
if(NOT TARGET DL::DL)
  add_library(DL::DL INTERFACE IMPORTED)
  set_target_properties(DL::DL PROPERTIES INTERFACE_LINK_LIBRARIES "dl"
    INTERFACE_LINK_DIRECTORIES "$REAL/lib")
endif()
if(NOT TARGET LibIntl::LibIntl)
  add_library(LibIntl::LibIntl INTERFACE IMPORTED)
  set_target_properties(LibIntl::LibIntl PROPERTIES INTERFACE_LINK_LIBRARIES "intl;iconv"
    INTERFACE_LINK_DIRECTORIES "$REAL/lib")
endif()
if(NOT TARGET Pthread::Pthread)
  add_library(Pthread::Pthread INTERFACE IMPORTED)
  set_target_properties(Pthread::Pthread PROPERTIES INTERFACE_LINK_LIBRARIES "pthread"
    INTERFACE_LINK_DIRECTORIES "$MINGW_TOOLCHAIN/x86_64-w64-mingw32/lib")
endif()
PRELUDE

# ── 工具链文件（静态变体）─────────────────────────────────────
cat > $SC/toolchain-static.cmake <<EOF
# CMP0077 NEW：libime 顶层 option(BUILD_SHARED_LIBS) 尊重命令行传入值（否则被清除回默认 SHARED）。
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR AMD64)
set(CMAKE_C_COMPILER $CC)
set(CMAKE_CXX_COMPILER $CXX)
set(CMAKE_RC_COMPILER $MINGW_TOOLCHAIN/bin/x86_64-w64-mingw32-windres)
set(CMAKE_AR $MINGW_TOOLCHAIN/bin/x86_64-w64-mingw32-ar CACHE FILEPATH "")
set(CMAKE_RANLIB $MINGW_TOOLCHAIN/bin/x86_64-w64-mingw32-ranlib CACHE FILEPATH "")
set(BUILD_SHARED_LIBS OFF)
# 标准库附加在链接行对象之后：IMECore/Fcitx5Utils 静态库的传递依赖在此补齐。
set(CMAKE_CXX_STANDARD_LIBRARIES "-lzstd -lintl -liconv -ldl -lz")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static -L$WC/msys-sysroot/clang64/lib -L$SC/deps-root/build/bin -L$SC/prefix/lib")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-L$WC/msys-sysroot/clang64/lib -L$SC/deps-root/build/bin -L$SC/prefix/lib")
set(CMAKE_FIND_ROOT_PATH $MINGW_TOOLCHAIN/x86_64-w64-mingw32 /usr/local/opt/boost $REAL $SC/prefix)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# ── ECM → Fcitx5Utils（静态）→ libime（静态）──────────────────
cmake -S ecm -B ecm-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$SC/toolchain-static.cmake -DCMAKE_INSTALL_PREFIX=$SC/prefix \
  -DBUILD_TESTING=OFF -DBUILD_DOC=OFF >/dev/null
cmake --build ecm-build -j 8 >/dev/null
cmake --install ecm-build >/dev/null

FCITX_OPTS=(-DENABLE_TEST=OFF -DENABLE_TESTING_ADDONS=OFF -DENABLE_X11=OFF
  -DENABLE_WAYLAND=OFF -DENABLE_DBUS=OFF -DENABLE_ENCHANT=OFF -DENABLE_SERVER=OFF
  -DENABLE_KEYBOARD=OFF -DENABLE_EMOJI=OFF -DENABLE_LIBUUID=OFF
  -DBUILD_SPELL_DICT=OFF -DENABLE_XDGAUTOSTART=OFF -DEVENT_LOOP_BACKEND=none)
cmake -S fcitx5 -B fcitx5-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$SC/toolchain-static.cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$SC/prefix -DCMAKE_PREFIX_PATH=$SC/prefix "${FCITX_OPTS[@]}" >/dev/null
cmake --build fcitx5-build --target Fcitx5Utils -j 8 >/dev/null
cmake --install fcitx5-build/src/lib/fcitx-utils >/dev/null

LIBIME_OPTS=(-DENABLE_TEST=OFF -DENABLE_DATA=OFF -DENABLE_DOC=OFF -DENABLE_TOOLS=ON
  -DCMAKE_CXX_FLAGS=-D_LIBCPP_ENABLE_CXX17_REMOVED_UNARY_BINARY_FUNCTION)
cmake -S libime -B libime-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_SKIP_INSTALL_RULES=ON \
  -DCMAKE_PROJECT_INCLUDE=$SC/consumer-prelude.cmake \
  -DCMAKE_TOOLCHAIN_FILE=$SC/toolchain-static.cmake -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$SC/prefix -DCMAKE_PREFIX_PATH=$SC/prefix "${LIBIME_OPTS[@]}" >/dev/null
cmake --build libime-build --target IMEPinyin libime_pinyindict libime_slm_build_binary -j 8 >/dev/null
# 静态库落位到 core 的 link_directories（deps-root/build/bin＋prefix/lib）
mkdir -p $SC/deps-root/build/bin
find libime-build -name 'lib*.a' -exec cp -f {} $SC/deps-root/build/bin/ \; 2>/dev/null || true
find fcitx5-build -name 'libFcitx5Utils.a' -exec cp -f {} $SC/deps-root/build/bin/ \; 2>/dev/null || true

# ── GogakuCore 静态副本（fsync/WIN32/导出宏三处注入）──────────
rm -rf core-src core-src.tmp
mkdir -p core-src core-src.tmp
# 从 git HEAD 提取核心源码：排除工作区里其他并行会话的未提交 WIP，
# 保证自检包构建自已验证的提交状态（与版本规则一致）。
git -C $ROOT archive HEAD native/GogakuCore native/third_party | tar -x -C core-src.tmp
mv core-src.tmp/native/GogakuCore/* core-src/
# 共享第三方（json.hpp）必须与 core-src 平级，CMake 从 core-src/../third_party 找。
mv core-src.tmp/native/third_party $SC/third_party
rm -rf core-src.tmp
python3 - "$SC/core-src" <<'PYEOF'
import sys
root = sys.argv[1]
# 注入 1：fsync → _commit
block = ('#ifdef _WIN32\n'
         '/* Windows 无 fsync。_commit 对 O_RDONLY 句柄会失败而旧写入路径把\n'
         ' * fsync 失败当致命错误；自检包关注功能兼容而非掉电顺序，此处置为\n'
         ' * 无操作（内联函数而非宏：::fsync 作用域写法同样生效）。正式上游化\n'
         ' * 应对写句柄用 FlushFileBuffers。*/\n'
         'static inline int fsync(int) { return 0; }\n#endif\n')
for name in ['custom_words.cpp', 'normal_session.cpp']:
    p = f'{root}/{name}'
    s = open(p).read()
    if '#define fsync _commit' not in s:
        s = s.replace('#include <unistd.h>\n', '#include <unistd.h>\n\n' + block, 1)
        open(p, 'w').write(s)
        print(f'fsync compat injected: {name}')
# 注入 2：WIN32 输出目录自引用修正（静态版无 DLL，直接删掉坏块）。
p = f'{root}/CMakeLists.txt'
s = open(p).read()
broken = ('if(WIN32)\n'
          '  set_target_properties(GogakuCore PROPERTIES RUNTIME_OUTPUT_DIRECTORY '
          '$<TARGET_FILE_DIR:GogakuCore>)\nendif()\n')
if broken in s:
    s = s.replace(broken, '')
    open(p, 'w').write(s)
    print('WIN32 broken block removed: CMakeLists.txt')
# 注入 2a'：剥离 visibility hidden（静态档案符号必须对外可见）。
if 'CXX_VISIBILITY_PRESET hidden' in s:
    s = s.replace(' CXX_VISIBILITY_PRESET hidden', '').replace(' VISIBILITY_INLINES_HIDDEN ON', '')
    open(p, 'w').write(s)
    print('visibility stripped: CMakeLists.txt')
# 注入 2a''：目录级 link_directories——bench/fuzz 等目标缺 target 级声明。
if 'link_directories("${GOGAKU_DEPS}/build/bin"' not in s:
    anchor = 'if(NOT DEFINED GOGAKU_DEPS)'
    s = s.replace(anchor, anchor + '\nlink_directories("${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")')
    open(p, 'w').write(s)
    print('directory link_directories added: CMakeLists.txt')
# 注入 2b：add_library(GogakuCore SHARED …) → 由 BUILD_SHARED_LIBS 决定。
if 'add_library(GogakuCore SHARED' in s:
    s = s.replace('add_library(GogakuCore SHARED', 'add_library(GogakuCore', 1)
    open(p, 'w').write(s)
    print('GogakuCore target made type-agnostic (BUILD_SHARED_LIBS): CMakeLists.txt')
# 注入 3：导出宏——静态变体不 dllexport/dllimport。
p = f'{root}/include/gogaku_core.h'
s = open(p).read()
old = '''#if defined(_WIN32)
#  if defined(GOGAKU_CORE_BUILDING)
#    define GOGAKU_CORE_EXPORT __declspec(dllexport)
#  else
#    define GOGAKU_CORE_EXPORT __declspec(dllimport)
#  endif
#else'''
new = '''#if defined(_WIN32) && defined(GOGAKU_CORE_DYNAMIC)
#  if defined(GOGAKU_CORE_BUILDING)
#    define GOGAKU_CORE_EXPORT __declspec(dllexport)
#  else
#    define GOGAKU_CORE_EXPORT __declspec(dllimport)
#  endif
#elif defined(_WIN32)
#  define GOGAKU_CORE_EXPORT
#else'''
if old in s:
    s = s.replace(old, new)
    open(p, 'w').write(s)
    print('export macro adjusted for static: include/gogaku_core.h')
# 注入 4：测试 mkdtemp 模板 /tmp → %TEMP%（Windows 无 /tmp，否则静默 SKIP）。
for name in ['tests/normal_session_test.cpp', 'tests/learning_session_test.cpp']:
    p = f'{root}/{name}'
    s = open(p).read()
    changed = False
    for lit in ['"/tmp/gogaku-core-test-XXXXXX"', '"/tmp/gogaku-learning-test-XXXXXX"']:
        if lit in s:
            var = 'gogaku-core-test-XXXXXX' if 'core-test' in lit else 'gogaku-learning-test-XXXXXX'
            repl = ('static char tplBuf[512]; snprintf(tplBuf, sizeof(tplBuf), '
                    '"%s\\\\' + var + '", getenv("TEMP") ? getenv("TEMP") : "."); '
                    'char *tpl = tplBuf;')
            s = s.replace('char tpl[] = ' + lit + ';', repl)
            changed = True
    if changed:
        open(p, 'w').write(s)
        print(f'mkdtemp TEMP-path injected: {name}')
# 注入 5a：rename 不覆盖已存在目标 → 原子写第二次起静默失败（删词复活等）。
# Windows 无 POSIX rename 语义；测试包用先移除再改名，产品化应改
# MoveFileExA + MOVEFILE_REPLACE_EXISTING 保持原子性。
p = f'{root}/normal_session.cpp'
s = open(p).read()
old_rn = "    if (std::rename(temp.c_str(), path.c_str()) != 0) {"
if old_rn in s:
    s = s.replace(old_rn, "#ifdef _WIN32\n    // MSVCRT/MinGW rename 不覆盖已存在目标；先移除旧文件再改名。\n    ::remove(path.c_str());\n#endif\n" + old_rn)
    open(p, 'w').write(s)
    print('rename-replace fix injected: normal_session.cpp')
old_aw = '''        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        out.flush();
        if (!out.good()) return false;
    }
    {
        int fd = ::open(temp.c_str(), O_RDONLY);
        if (fd < 0) return false;
        if (::fsync(fd) != 0) {
            ::close(fd);
            std::remove(temp.c_str());
            return false;
        }
        ::close(fd);
    }
    if (std::rename(temp.c_str(), path.c_str()) != 0) {
        std::remove(temp.c_str());
        return false;
    }'''
new_aw = '''        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        out.flush();
        if (!out.good()) return false;
    }
    {
        int fd = ::open(temp.c_str(), O_RDONLY);
        if (fd < 0) return false;
        if (::fsync(fd) != 0) {
            ::close(fd);
            std::remove(temp.c_str());
            return false;
        }
        ::close(fd);
    }
    if (std::rename(temp.c_str(), path.c_str()) != 0) {
        std::remove(temp.c_str());
        return false;
    }'''
if old_aw in s:
    s = s.replace(old_aw, new_aw)
    open(p, 'w').write(s)
    print('atomic_write DBG probes injected: normal_session.cpp')
PYEOF

# deps-root 形状（libime install 静态库到 static/prefix）
mkdir -p $SC/deps-root
rm -rf $SC/deps-root/build $SC/deps-root/source $SC/deps-root/prefix
ln -sfn $WC/deps/libime $SC/deps-root/source
ln -sfn $SC/libime-build $SC/deps-root/build
ln -sfn $SC/prefix $SC/deps-root/prefix
mkdir -p $SC/deps-root/build/bin
# 静态库落位到 core 的 link_directories（deps-root/build/bin）
find libime-build -name 'lib*.a' -exec cp -f {} $SC/deps-root/build/bin/ \; 2>/dev/null || true
find fcitx5-build -name 'libFcitx5Utils.a' -exec cp -f {} $SC/deps-root/build/bin/ \; 2>/dev/null || true

rm -rf $SC/core-build
BOOST_INCLUDE=/usr/local/opt/boost/include \
cmake -S core-src -B core-build -G Ninja -DCMAKE_MAKE_PROGRAM=$NINJA \
  -DCMAKE_TOOLCHAIN_FILE=$SC/toolchain-static.cmake -DCMAKE_BUILD_TYPE=Release \
  -DGOGAKU_DEPS=$SC/deps-root >/dev/null
cmake --build core-build -j 8 > /tmp/static-core-build.log 2>&1 || {
  grep -E "error|FAILED" /tmp/static-core-build.log | head -10; exit 1; }

# 静态产物位置动态定位（exe 可能在构建根或 bin/）
BIN=$SC/core-build
for f in gogaku_core_abi_test gogaku_core_translate_safety_test gogaku_core_normal_test \
         gogaku_core_learning_test gogaku_core_quality_test gogaku_core_fuzz; do
  find $BIN -maxdepth 2 -name "$f.exe" -exec mv -f {} $BIN/ \; 2>/dev/null || true
done
find $BIN -maxdepth 2 -name 'libgogaku_core.a' -exec mv -f {} $BIN/ \; 2>/dev/null || true
ls $BIN/*.exe 2>/dev/null | head -10

# ── 合链：改名 main ＋ 数据内嵌 ＋ runner ─────────────────────
mkdir -p $SC/combine
cd $SC/combine
BIN=$SC/core-build
CORE_SRC=$SC/core-src
DATA=$HOME/Library/Caches/Gogaku/libime-1.1.17/data
INC="-I$CORE_SRC/include -I$SC/third_party -I$SC/deps-root/source/src -I$SC/deps-root/build/src -I$SC/deps-root/prefix/include/Fcitx5/Utils -I/usr/local/opt/boost/include -O2 -DNDEBUG -std=gnu++20"

$CXX $INC -Dmain=test_main_safety    -c $CORE_SRC/tests/translate_safety_test.cpp -o safety.o
$CXX $INC -Dmain=test_main_normal    -c $CORE_SRC/tests/normal_session_test.cpp   -o normal.o 2>/dev/null || \
  $CC  $INC -Dmain=test_main_normal  -c $CORE_SRC/tests/normal_session_test.cpp   -o normal.o
$CXX $INC -Dmain=test_main_learning  -c $CORE_SRC/tests/learning_session_test.cpp -o learning.o
$CXX $INC -Dmain=test_main_quality   -c $CORE_SRC/tests/normal_session_quality.cpp -o quality.o
$CXX $INC -Dmain=test_main_fuzz      -c $CORE_SRC/tests/normal_session_fuzz.cpp   -o fuzz.o
$CC  $INC -Dmain=test_main_abi       -c $CORE_SRC/tests/abi_version_test.c        -o abi.o
# 设置契约向量：与 Mac ctest 跑同一份源码，Windows 侧不再只靠注释对照。
$CXX $INC -Dmain=test_main_settings  -c $CORE_SRC/tests/settings_contract_test.cpp -o settings.o

# 数据内嵌（短文件名控制符号名）
cp "$DATA/sc.dict"  embed_sc_dict.bin
cp "$DATA/zh_CN.lm" embed_zh_cn_lm.bin
$OBJCOPY -I binary -O pe-x86-64 -B i386 embed_sc_dict.bin  embed_sc_dict.bin.o
$OBJCOPY -I binary -O pe-x86-64 -B i386 embed_zh_cn_lm.bin embed_zh_cn_lm.bin.o

cat > runner.cpp <<'EOF'
// Gogaku 共享核心 Windows 单文件自检程序。
// 启动时把内嵌出厂数据解压到 %TEMP%，顺序运行六项测试并汇总一行结论。
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <direct.h>
#include <stdlib.h>

extern "C" int test_main_abi(void);
int test_main_safety(void);
int test_main_normal(void);
int test_main_learning(void);
int test_main_quality(void);
int test_main_settings(void);
int test_main_fuzz(int argc, char** argv);

extern const unsigned char _binary_embed_sc_dict_bin_start[];
extern const unsigned char _binary_embed_sc_dict_bin_end[];
extern const unsigned char _binary_embed_zh_cn_lm_bin_start[];
extern const unsigned char _binary_embed_zh_cn_lm_bin_end[];

static bool write_embedded(const std::string& dir, const char* name,
                           const unsigned char* s, const unsigned char* e) {
    FILE* f = fopen((dir + "\\" + name).c_str(), "wb");
    if (!f) return false;
    const size_t n = static_cast<size_t>(e - s);
    const bool ok = fwrite(s, 1, n, f) == n;
    return fclose(f) == 0 && ok;
}

int main() {
    printf("Gogaku 共享核心自检（单文件版）\n");
    printf("================================\n\n");
    const char* temp = getenv("TEMP");
    if (!temp || !*temp) temp = getenv("TMP");
    if (!temp || !*temp) temp = "C:\\Windows\\Temp";
    std::string dir = std::string(temp) + "\\gogaku-selfcheck-data";
    _mkdir(dir.c_str());
    const bool dataOk =
        write_embedded(dir, "sc.dict", _binary_embed_sc_dict_bin_start, _binary_embed_sc_dict_bin_end) &&
        write_embedded(dir, "zh_CN.lm", _binary_embed_zh_cn_lm_bin_start, _binary_embed_zh_cn_lm_bin_end);
    if (!dataOk) {
        printf("[失败] 测试数据写盘失败（%s）\n\n", dir.c_str());
        printf("按回车键退出..."); getchar();
        return 2;
    }
    static char envBuf[600];
    snprintf(envBuf, sizeof(envBuf), "GOGAKU_CORE_TEST_DATA=%s", dir.c_str());
    _putenv(envBuf);

    struct { const char* name; int (*run)(); } tests[] = {
        {"ABI 版本合同",       [] { return test_main_abi(); }},
        {"翻译加固层",         [] { return test_main_safety(); }},
        {"普通模式轨迹",       [] { return test_main_normal(); }},
        {"学习模式轨迹",       [] { return test_main_learning(); }},
        {"质量回归（120 条）", [] { return test_main_quality(); }},
        {"设置契约向量",     [] { return test_main_settings(); }},
        {"随机序列冒烟",       [] { char n0[] = "fuzz"; char s0[] = "20261031"; char c0[] = "2000";
                                   char* av[] = {n0, s0, c0}; return test_main_fuzz(3, av); }},
    };
    int failures = 0;
    for (const auto& t : tests) {
        printf("—— %s ——\n", t.name);
        const int code = t.run();
        printf(">>> %s：%s\n\n", t.name, code == 0 ? "通过" : (code == 3 ? "跳过（缺数据）" : "失败"));
        if (code != 0) ++failures;
    }
    printf("================\n");
    printf("%s（失败 %d 项）。请截图本窗口全部内容发回。\n", failures == 0 ? "全部通过 ✅" : "存在失败 ❌", failures);
    printf("按回车键退出...");
    getchar();
    return failures == 0 ? 0 : 1;
}
EOF
$CXX $INC -c runner.cpp -o runner.o
$CXX -static runner.o abi.o safety.o normal.o learning.o quality.o settings.o fuzz.o \
  embed_sc_dict.bin.o embed_zh_cn_lm.bin.o \
  $BIN/libgogaku_core.a \
  -L$SC/deps-root/build/bin -L$SC/prefix/lib -L$WC/msys-sysroot/clang64/lib \
  -lIMEPinyin -lIMECore -lFcitx5Utils -lzstd -lintl -liconv -ldl -lz -lbcrypt -ladvapi32 \
  -o gogaku-selfcheck.exe
file gogaku-selfcheck.exe | head -1
ls -lh gogaku-selfcheck.exe | awk '{print $5}'
echo "EXE-BUILD-OK"
