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

add_library(GogakuCore SHARED core.cpp normal_session.cpp custom_words.cpp
    learning_session.cpp translate/translate_safety.cpp settings_contract.cpp)
target_include_directories(GogakuCore
    PRIVATE "${GOGAKU_DEPS}/source/src" "${GOGAKU_DEPS}/build/src" "${GOGAKU_DEPS}/prefix/include/Fcitx5/Utils" "${BOOST_INCLUDE}" "${CMAKE_CURRENT_SOURCE_DIR}/../third_party"
    PUBLIC include)
target_link_directories(GogakuCore PRIVATE "${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")
target_link_libraries(GogakuCore PRIVATE IMEPinyin IMECore Fcitx5Utils)
target_compile_definitions(GogakuCore PRIVATE GOGAKU_CORE_BUILDING)
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
add_executable(gogaku_core_learning_test tests/learning_session_test.cpp)
target_include_directories(gogaku_core_learning_test PRIVATE include "${GOGAKU_DEPS}/source/src" "${GOGAKU_DEPS}/build/src" "${GOGAKU_DEPS}/prefix/include/Fcitx5/Utils" "${BOOST_INCLUDE}")
target_link_directories(gogaku_core_learning_test PRIVATE "${GOGAKU_DEPS}/build/bin" "${GOGAKU_DEPS}/prefix/lib")
target_link_libraries(gogaku_core_learning_test PRIVATE GogakuCore IMEPinyin IMECore Fcitx5Utils)
gogaku_enable_sanitizers(gogaku_core_learning_test)
add_test(NAME learning_session COMMAND gogaku_core_learning_test)

# 中文质量回归：120 条冻结用例的首选／前十门槛与调频／自定义词不干扰检查。
add_executable(gogaku_core_quality_test tests/normal_session_quality.cpp)
target_include_directories(gogaku_core_quality_test PRIVATE include)
target_link_libraries(gogaku_core_quality_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_quality_test)
add_test(NAME quality_regression COMMAND gogaku_core_quality_test)
set_tests_properties(quality_regression PROPERTIES SKIP_RETURN_CODE 3)

# 翻译加固层回归：纯文本规则，无词典依赖（2026-11-02 模型路线裁决的处置手段）。
add_executable(gogaku_core_translate_safety_test tests/translate_safety_test.cpp)
target_include_directories(gogaku_core_translate_safety_test PRIVATE include)
target_link_libraries(gogaku_core_translate_safety_test PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_core_translate_safety_test)
add_test(NAME translate_safety COMMAND gogaku_core_translate_safety_test)

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

# 数据可靠性测试辅助进程（probes/validate-data-reliability.py 启动／校验）。
add_executable(gogaku_data_reliability_worker tests/data_reliability_worker.cpp)
target_include_directories(gogaku_data_reliability_worker PRIVATE include)
target_link_libraries(gogaku_data_reliability_worker PRIVATE GogakuCore)
gogaku_enable_sanitizers(gogaku_data_reliability_worker)
