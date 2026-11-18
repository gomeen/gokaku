cmake_minimum_required(VERSION 3.25)
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(GogakuPanelRender LANGUAGES C CXX)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(GOGAKU_FT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/freetype)
set(GOGAKU_HB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/harfbuzz)
set(GOGAKU_ZLIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/zlib)
set(GOGAKU_PNG_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../third_party/libpng)

add_library(gogaku_zlib STATIC ${GOGAKU_ZLIB_DIR}/adler32.c
    ${GOGAKU_ZLIB_DIR}/compress.c ${GOGAKU_ZLIB_DIR}/crc32.c
    ${GOGAKU_ZLIB_DIR}/deflate.c ${GOGAKU_ZLIB_DIR}/infback.c
    ${GOGAKU_ZLIB_DIR}/inffast.c ${GOGAKU_ZLIB_DIR}/inflate.c
    ${GOGAKU_ZLIB_DIR}/inftrees.c ${GOGAKU_ZLIB_DIR}/trees.c
    ${GOGAKU_ZLIB_DIR}/uncompr.c ${GOGAKU_ZLIB_DIR}/zutil.c)
target_include_directories(gogaku_zlib PUBLIC ${GOGAKU_ZLIB_DIR})
target_compile_definitions(gogaku_zlib PRIVATE ZLIB_INTERNAL)

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
target_include_directories(gogaku_freetype PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/ftconfig
    ${GOGAKU_PNG_DIR})
target_compile_definitions(gogaku_freetype PRIVATE FT2_BUILD_LIBRARY
    FT_CONFIG_MODULES_H=<ftmodule.h> FT_CONFIG_OPTION_USE_PNG)
target_include_directories(gogaku_freetype PUBLIC ${GOGAKU_FT_DIR}/include)
target_link_libraries(gogaku_freetype PRIVATE gogaku_png)

add_library(gogaku_harfbuzz STATIC ${GOGAKU_HB_DIR}/src/harfbuzz.cc)
target_include_directories(gogaku_harfbuzz PUBLIC ${GOGAKU_HB_DIR}/src)
target_compile_definitions(gogaku_harfbuzz PRIVATE HAVE_FREETYPE=1
    HB_NO_DIRECTWRITE HB_NO_CORETEXT HB_NO_ICU HB_NO_CAIRO HB_NO_GDI HB_NO_UNISCRIBE)
target_link_libraries(gogaku_harfbuzz PUBLIC gogaku_freetype)

add_library(GogakuPanelRender STATIC panel_render.cpp)
target_include_directories(GogakuPanelRender
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..
    PRIVATE ${GOGAKU_PNG_DIR} ${CMAKE_CURRENT_SOURCE_DIR}/../..)
if(GOGAKU_PANEL_EXPORTS)
    target_compile_definitions(GogakuPanelRender PRIVATE GOGAKU_CORE_BUILDING)
else()
    target_compile_definitions(GogakuPanelRender PUBLIC GOGAKU_SETTINGS_CONTRACT_STATIC)
endif()
target_link_libraries(GogakuPanelRender PUBLIC gogaku_harfbuzz PRIVATE gogaku_png)

# 子目录和独立 x86/x64 构建共用同一配置；HB 保持内部线程安全。
foreach(target GogakuPanelRender gogaku_harfbuzz gogaku_freetype gogaku_png gogaku_zlib)
    set_target_properties(${target} PROPERTIES POSITION_INDEPENDENT_CODE ON
        C_VISIBILITY_PRESET hidden CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON)
    if(MSVC)
        target_compile_options(${target} PRIVATE /utf-8)
    endif()
    if(GOGAKU_SANITIZERS)
        target_compile_options(${target} PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer -g)
        target_link_options(${target} INTERFACE -fsanitize=address,undefined)
    endif()
endforeach()
