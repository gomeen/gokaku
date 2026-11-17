cmake_minimum_required(VERSION 3.25)
project(GogakuCore LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED GOGAKU_DEPS)
  message(FATAL_ERROR "Pass -DGOGAKU_DEPS with pinned dependency cache (libime 1.1.17)")
endif()
# Boost 头文件：Mac 用 brew 路径；Windows（MSYS2 Clang64）由环境变量
# BOOST_INCLUDE 指示（scripts/prepare-libime-windows.py 与 CI 设置），
# HINTS 优先后仍回退常规查找（Clang64 下 CMAKE_SYSTEM_PREFIX_PATH 含
# /clang64，通常能自动找到）。
find_path(BOOST_INCLUDE boost/version.hpp
    HINTS "$ENV{BOOST_INCLUDE}"
    PATHS /usr/local/opt/boost/include /opt/homebrew/opt/boost/include
    REQUIRED)

# 可选 ASan＋UBSan 构建（随机按键模糊测试用；常规构建不受影响）。
# 插桩必须同时作用于共享核心库与测试可执行：add_compile_options 只对其后
# 创建的目标生效，若核心库先于它创建，核心内部（normal_session.cpp 等）
# 不会被插桩，模糊测试的「无内存错误」结论无效。这里改为逐目标显式设置，
# 不依赖目标创建顺序。
set(GOGAKU_SANITIZER_COMPILE_FLAGS "")
set(GOGAKU_SANITIZER_LINK_FLAGS "")
if(GOGAKU_SANITIZERS)
  set(GOGAKU_SANITIZER_COMPILE_FLAGS -fsanitize=address,undefined -fno-omit-frame-pointer -g)
  set(GOGAKU_SANITIZER_LINK_FLAGS -fsanitize=address,undefined)
endif()

function(gogaku_enable_sanitizers target)
  if(GOGAKU_SANITIZERS)
    target_compile_options(${target} PRIVATE ${GOGAKU_SANITIZER_COMPILE_FLAGS})
    target_link_options(${target} PRIVATE ${GOGAKU_SANITIZER_LINK_FLAGS})
  endif()
endfunction()

# Windows DLL 与测试程序共用真实 bin 目录；不能用目标自身目录的生成器表达式。
if(WIN32)
  set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin")
endif()

option(GOGAKU_LITE "Build shared core without learning session" OFF)

# ── vendored 文本栈（候选窗位图渲染器）────────────────────────
# zlib 1.3.1 ＋ libpng 1.6.44（PNG sbix emoji 需要）＋ FreeType 2.14.3
# （FTL）＋ HarfBuzz 14.5.0（MIT），全部纯静态编入，两端同一份源码。
# FreeType 禁 brotli/harfbuzz 子集；libpng 只编核心读写源文件。
set(GOGAKU_FT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/freetype)
set(GOGAKU_HB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/harfbuzz)
set(GOGAKU_ZLIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/zlib)
set(GOGAKU_PNG_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libpng)
option(GOGAKU_PANEL_RENDER "Build panel bitmap renderer (HarfBuzz+FreeType)" ON)
if(GOGAKU_PANEL_RENDER)
    # zlib 核心（libpng 与 ftgzip 共用；不编 gz* 文件 IO）。静态符号不导出，
    # Windows 侧不与系统 zlib 冲突。
    add_library(gogaku_zlib STATIC ${GOGAKU_ZLIB_DIR}/adler32.c
        ${GOGAKU_ZLIB_DIR}/compress.c ${GOGAKU_ZLIB_DIR}/crc32.c
        ${GOGAKU_ZLIB_DIR}/deflate.c ${GOGAKU_ZLIB_DIR}/infback.c
        ${GOGAKU_ZLIB_DIR}/inffast.c ${GOGAKU_ZLIB_DIR}/inflate.c
        ${GOGAKU_ZLIB_DIR}/inftrees.c ${GOGAKU_ZLIB_DIR}/trees.c
        ${GOGAKU_ZLIB_DIR}/uncompr.c ${GOGAKU_ZLIB_DIR}/zutil.c)
    target_include_directories(gogaku_zlib PUBLIC ${GOGAKU_ZLIB_DIR})
    target_compile_definitions(gogaku_zlib PRIVATE ZLIB_INTERNAL)

    # libpng：pnglibconf.h 用上游预生成版。
    add_library(gogaku_png STATIC ${GOGAKU_PNG_DIR}/png.c
        ${GOGAKU_PNG_DIR}/pngerror.c ${GOGAKU_PNG_DIR}/pngget.c
        ${GOGAKU_PNG_DIR}/pngmem.c ${GOGAKU_PNG_DIR}/pngpread.c
        ${GOGAKU_PNG_DIR}/pngread.c ${GOGAKU_PNG_DIR}/pngrio.c
        ${GOGAKU_PNG_DIR}/pngrtran.c ${GOGAKU_PNG_DIR}/pngrutil.c
        ${GOGAKU_PNG_DIR}/pngset.c ${GOGAKU_PNG_DIR}/pngtrans.c
        ${GOGAKU_PNG_DIR}/pngwio.c ${GOGAKU_PNG_DIR}/pngwrite.c
        ${GOGAKU_PNG_DIR}/pngwtran.c ${GOGAKU_PNG_DIR}/pngwutil.c)
    target_include_directories(gogaku_png PUBLIC ${GOGAKU_PNG_DIR})
    target_link_libraries(gogaku_png PUBLIC gogaku_zlib)

    # 精简驱动集：base 用官方 unity（ftbase.c，含 ftobjs/ftcalc/ftstream…）
    # ＋ftbitmap，驱动只编 tt+cff+sfnt+autofit+pshinter+psnames+smooth+cache；
    # 候选窗只吃 ttc/ttf/otf，ps/bdf/pcf/winfonts/sdf/svg/gzip 不编入。
    # 自带精简 ftmodule.h（panel_render/ftconfig）只注册编入的模块。
    add_library(gogaku_freetype STATIC ${GOGAKU_FT_DIR}/src/base/ftsystem.c
        ${GOGAKU_FT_DIR}/src/base/ftinit.c ${GOGAKU_FT_DIR}/src/base/ftdebug.c
        ${GOGAKU_FT_DIR}/src/base/ftbase.c ${GOGAKU_FT_DIR}/src/base/ftbitmap.c
        ${GOGAKU_FT_DIR}/src/base/ftmm.c ${GOGAKU_FT_DIR}/src/base/ftglyph.c
        ${GOGAKU_FT_DIR}/src/sfnt/sfnt.c
        ${GOGAKU_FT_DIR}/src/truetype/truetype.c ${GOGAKU_FT_DIR}/src/cff/cff.c
        ${GOGAKU_FT_DIR}/src/autofit/autofit.c ${GOGAKU_FT_DIR}/src/pshinter/pshinter.c
        ${GOGAKU_FT_DIR}/src/psnames/psnames.c ${GOGAKU_FT_DIR}/src/psaux/psaux.c
        ${GOGAKU_FT_DIR}/src/raster/raster.c
        ${GOGAKU_FT_DIR}/src/smooth/smooth.c ${GOGAKU_FT_DIR}/src/cache/ftcache.c
        ${GOGAKU_FT_DIR}/src/gzip/ftgzip.c)
    target_include_directories(gogaku_freetype PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/panel_render/ftconfig)
    target_compile_definitions(gogaku_freetype PRIVATE FT2_BUILD_LIBRARY
        FT_CONFIG_MODULES_H=<ftmodule.h> FT_CONFIG_OPTION_USE_PNG)
    target_include_directories(gogaku_freetype PRIVATE ${GOGAKU_PNG_DIR})
    target_link_libraries(gogaku_freetype PRIVATE gogaku_png)
    target_include_directories(gogaku_freetype PUBLIC ${GOGAKU_FT_DIR}/include)
    add_library(gogaku_harfbuzz STATIC ${GOGAKU_HB_DIR}/src/harfbuzz.cc)
    target_include_directories(gogaku_harfbuzz PUBLIC ${GOGAKU_HB_DIR}/src)
    target_compile_definitions(gogaku_harfbuzz PRIVATE HAVE_FREETYPE=1
        HB_NO_DIRECTWRITE HB_NO_CORETEXT HB_NO_ICU HB_NO_CAIRO HB_NO_GDI HB_NO_UNISCRIBE
        HB_NO_MT)
    target_link_libraries(gogaku_harfbuzz PUBLIC gogaku_freetype)
endif()

set(GOGAKU_CORE_SOURCES core.cpp normal_session.cpp custom_words.cpp
    settings_contract.cpp theme_contract.cpp)
if(GOGAKU_PANEL_RENDER)
    list(INSERT GOGAKU_CORE_SOURCES 0 panel_render/panel_render.cpp)
endif()
if(GOGAKU_LITE)
    list(APPEND GOGAKU_CORE_SOURCES learning_session_stub.cpp)
else()
    list(APPEND GOGAKU_CORE_SOURCES learning_session.cpp translate/translate_safety.cpp)
endif()
add_library(GogakuCore SHARED ${GOGAKU_CORE_SOURCES})
target_include_directories(GogakuCore
    PRIVATE "${GOGAKU_DEPS}/source/src" "${GOGAKU_DEPS}/build/src" "${GOGAKU_DEPS}/prefix/include/Fcitx5/Utils" "${BOOST_INCLUDE}" "${CMAKE_CURRENT_SOURCE_DIR}/../third_party"
    PUBLIC include)
target_link_directories(GogakuCore PRIVATE "${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")
target_link_libraries(GogakuCore PRIVATE IMEPinyin IMECore Fcitx5Utils)
target_compile_definitions(GogakuCore PRIVATE GOGAKU_CORE_BUILDING)
if(GOGAKU_LITE)
    target_compile_definitions(GogakuCore PUBLIC GOGAKU_LITE=1)
endif()
if(GOGAKU_PANEL_RENDER)
    target_link_libraries(GogakuCore PRIVATE gogaku_harfbuzz)
endif()
set_target_properties(GogakuCore PROPERTIES
    OUTPUT_NAME gogaku_core
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    BUILD_RPATH "${GOGAKU_DEPS}/build/bin;${GOGAKU_DEPS}/prefix/lib"
    INSTALL_NAME_DIR "@rpath")
if(WIN32)
  target_link_libraries(GogakuCore PRIVATE advapi32 bcrypt)
endif()

# 核心库自身也插桩（见上：只插桩测试壳无法覆盖核心内部）。
gogaku_enable_sanitizers(GogakuCore)

enable_testing()
# ABI 版本合同测试（C，不依赖 libime 数据）。
add_executable(gogaku_core_abi_test tests/abi_version_test.c)
target_include_directories(gogaku_core_abi_test PRIVATE include)
target_link_libraries(gogaku_core_abi_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_abi_test)
add_test(NAME abi_version COMMAND gogaku_core_abi_test)

# 用户数据持久化：Unicode 路径、重复替换、备份及 Windows 写盘故障注入。
# 不依赖词典数据；交叉构建只编译此测试，不在 Mac 上执行 Windows 程序。
add_executable(gogaku_core_persistence_test tests/persistence_test.cpp)
target_link_libraries(gogaku_core_persistence_test PRIVATE GogakuCore)
if(WIN32)
  target_link_libraries(gogaku_core_persistence_test PRIVATE advapi32 bcrypt)
endif()
gogaku_enable_sanitizers(gogaku_core_persistence_test)
add_test(NAME persistence COMMAND gogaku_core_persistence_test)

# 同一普通会话写失败后不重新学习也能重试；Unicode 路径重载／清空／备份。
add_executable(gogaku_core_normal_persistence_test tests/normal_persistence_test.cpp)
target_link_libraries(gogaku_core_normal_persistence_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_normal_persistence_test)
add_test(NAME persistence_normal COMMAND gogaku_core_normal_persistence_test)
set_tests_properties(persistence_normal PROPERTIES SKIP_RETURN_CODE 3)

# 普通模式事件轨迹测试。词典/模型路径经环境变量提供
# （GOGAKU_CORE_TEST_DATA），与本机缓存保持一致；测试词典由文本格式临时生成，
# 需直接包含 libime 头。
add_executable(gogaku_core_normal_test tests/normal_session_test.cpp)
target_include_directories(gogaku_core_normal_test PRIVATE include "${GOGAKU_DEPS}/source/src" "${GOGAKU_DEPS}/build/src" "${GOGAKU_DEPS}/prefix/include/Fcitx5/Utils" "${BOOST_INCLUDE}")
target_link_directories(gogaku_core_normal_test PRIVATE "${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")
target_link_libraries(gogaku_core_normal_test PRIVATE GogakuCore IMEPinyin IMECore Fcitx5Utils)
gogaku_enable_sanitizers(gogaku_core_normal_test)
add_test(NAME normal_session COMMAND gogaku_core_normal_test)

# 万次事件性能基准（手动运行，不计入 ctest）。
add_executable(gogaku_core_normal_bench tests/normal_session_bench.cpp)
target_include_directories(gogaku_core_normal_bench PRIVATE include)
target_link_libraries(gogaku_core_normal_bench PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_normal_bench)

# 分项成本基准（手动运行，不计入 ctest）：拆测解码／候选／合并／查询／快照。
# 直接使用 libime 头，需与核心相同的依赖路径。
add_executable(gogaku_core_normal_profile tests/normal_session_profile.cpp)
target_include_directories(gogaku_core_normal_profile PRIVATE include "${GOGAKU_DEPS}/source/src" "${GOGAKU_DEPS}/build/src" "${GOGAKU_DEPS}/prefix/include/Fcitx5/Utils" "${BOOST_INCLUDE}")
target_link_directories(gogaku_core_normal_profile PRIVATE "${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")
target_link_libraries(gogaku_core_normal_profile PRIVATE GogakuCore IMEPinyin IMECore Fcitx5Utils)
gogaku_enable_sanitizers(gogaku_core_normal_profile)

# 学习模式事件轨迹测试（ABI v3）：学习组合状态机＋翻译调度合同＋三状态语义。
# 词典/模型路径同普通模式测试（GOGAKU_CORE_TEST_DATA）；测试词典临时生成。
if(NOT GOGAKU_LITE)
    add_executable(gogaku_core_learning_test tests/learning_session_test.cpp)
    target_include_directories(gogaku_core_learning_test PRIVATE include "${GOGAKU_DEPS}/source/src" "${GOGAKU_DEPS}/build/src" "${GOGAKU_DEPS}/prefix/include/Fcitx5/Utils" "${BOOST_INCLUDE}")
    target_link_directories(gogaku_core_learning_test PRIVATE "${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")
    target_link_libraries(gogaku_core_learning_test PRIVATE GogakuCore IMEPinyin IMECore Fcitx5Utils)
    gogaku_enable_sanitizers(gogaku_core_learning_test)
    add_test(NAME learning_session COMMAND gogaku_core_learning_test)
endif()

# 中文质量回归：120 条冻结用例的首选／前十门槛与调频／自定义词不干扰检查。
add_executable(gogaku_core_quality_test tests/normal_session_quality.cpp)
target_include_directories(gogaku_core_quality_test PRIVATE include)
target_link_libraries(gogaku_core_quality_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_quality_test)
add_test(NAME quality_regression COMMAND gogaku_core_quality_test)
set_tests_properties(quality_regression PROPERTIES SKIP_RETURN_CODE 3)

# 翻译加固层回归：纯文本规则，无词典依赖（Lite 无 translate 单元）。
if(NOT GOGAKU_LITE)
    add_executable(gogaku_core_translate_safety_test tests/translate_safety_test.cpp)
    target_include_directories(gogaku_core_translate_safety_test PRIVATE include)
    target_link_libraries(gogaku_core_translate_safety_test PRIVATE GogakuCore)
    gogaku_enable_sanitizers(gogaku_core_translate_safety_test)
    add_test(NAME translate_safety COMMAND gogaku_core_translate_safety_test)
endif()

# 随机按键序列模糊测试（手动运行；默认种子与序列数即可覆盖 ≥10 万序列）。
add_executable(gogaku_core_fuzz tests/normal_session_fuzz.cpp)
target_include_directories(gogaku_core_fuzz PRIVATE include)
target_link_libraries(gogaku_core_fuzz PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_fuzz)
# 常规构建的冒烟模糊测试（复查 E1：缺数据时显式 SKIP 退出码 3，不当作通过）。
add_test(NAME fuzz_smoke COMMAND gogaku_core_fuzz 20261031 2000)
set_tests_properties(fuzz_smoke PROPERTIES SKIP_RETURN_CODE 3)

# 设置契约向量：读侧规范化（默认值、类型鉗制、schema 迁移）。
# 无词典依赖，两端跑同一份源码； Windows 自检包也包含它。
add_executable(gogaku_core_settings_contract_test tests/settings_contract_test.cpp)
target_include_directories(gogaku_core_settings_contract_test PRIVATE include "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
target_link_libraries(gogaku_core_settings_contract_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_settings_contract_test)
add_test(NAME settings_contract COMMAND gogaku_core_settings_contract_test)

# 内置主题契约向量：四套主题的调色板与排版（共享数据冻结）。
add_executable(gogaku_core_theme_contract_test tests/theme_contract_test.cpp)
target_include_directories(gogaku_core_theme_contract_test PRIVATE include "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
target_link_libraries(gogaku_core_theme_contract_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_theme_contract_test)
add_test(NAME theme_contract COMMAND gogaku_core_theme_contract_test)

# 候选窗位图渲染契约向量：布局几何、命中区域、错误路径（需 GOGAKU_PANEL_FONT）。
add_executable(gogaku_core_panel_render_test tests/panel_render_test.cpp)
target_include_directories(gogaku_core_panel_render_test PRIVATE include "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
target_link_libraries(gogaku_core_panel_render_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_panel_render_test)
add_test(NAME panel_render COMMAND gogaku_core_panel_render_test)
# 字体路径经环境变量注入（ctest 继承父环境；verify.py 与手动跑都导出
# GOGAKU_PANEL_FONT）。configure 时为空则不覆盖，让测试进程直接继承。
set(GOGAKU_PANEL_FONT_DEFAULT "$ENV{GOGAKU_PANEL_FONT}")
if(GOGAKU_PANEL_FONT_DEFAULT)
    set_tests_properties(panel_render PROPERTIES ENVIRONMENT
        "GOGAKU_PANEL_FONT=${GOGAKU_PANEL_FONT_DEFAULT}")
endif()
set_tests_properties(panel_render PROPERTIES SKIP_RETURN_CODE 3)

# 数据可靠性测试辅助进程（probes/validate-data-reliability.py 启动／校验）。
add_executable(gogaku_data_reliability_worker tests/data_reliability_worker.cpp)
target_include_directories(gogaku_data_reliability_worker PRIVATE include)
target_link_libraries(gogaku_data_reliability_worker PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_data_reliability_worker)
