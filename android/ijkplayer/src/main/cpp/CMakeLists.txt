cmake_minimum_required(VERSION 3.22)

project(fsplayer)

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wno-int-conversion")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-int-conversion")

# ABI -> 库子目录后缀
if (ANDROID_ABI STREQUAL "arm64-v8a")
    set(ARCH "arm64")
elseif (ANDROID_ABI STREQUAL "armeabi-v7a")
    set(ARCH "armv7a")
elseif (ANDROID_ABI STREQUAL "x86")
    set(ARCH "x86")
elseif (ANDROID_ABI STREQUAL "x86_64")
    set(ARCH "x86_64")
else()
    message(FATAL_ERROR "Unsupported ANDROID_ABI: ${ANDROID_ABI}")
endif()

# 仓库根目录：本文件位于 android/ijkplayer/src/main/cpp/，向上 5 层即仓库根
get_filename_component(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../ ABSOLUTE)
set(ijkmedia ${REPO_ROOT}/ijkmedia)
include_directories(${ijkmedia})
include_directories(${ijkmedia}/ijkj4a)
include_directories(${ijkmedia}/ijksdl)
include_directories(${ijkmedia}/ijksdl/ffmpeg)
include_directories(${ijkmedia}/ijkplayer)

# 三方库（FFToolChain 预编译产物，运行 ./FFToolChain/main.sh install -p android 生成）
set(FFMPEG_DIR ${REPO_ROOT}/FFToolChain/build/product/android/ffmpeg-${ARCH})
set(UNI_DIR ${REPO_ROOT}/FFToolChain/build/product/android/universal)
include_directories(${FFMPEG_DIR}/include)
include_directories(${UNI_DIR}/ass/ass-${ARCH}/include)
include_directories(${UNI_DIR}/freetype/freetype-${ARCH}/include)
include_directories(${UNI_DIR}/fribidi/fribidi-${ARCH}/include)
include_directories(${UNI_DIR}/harfbuzz/harfbuzz-${ARCH}/include)
include_directories(${UNI_DIR}/unibreak/unibreak-${ARCH}/include)
include_directories(${UNI_DIR}/openssl/openssl-${ARCH}/include)

file(GLOB_RECURSE SOURCE_IJKJ4A ${ijkmedia}/ijkj4a/*.c ${ijkmedia}/ijkj4a/*.cpp)
file(GLOB_RECURSE SOURCE_SDL ${ijkmedia}/ijksdl/*.c ${ijkmedia}/ijksdl/*.cpp)
file(GLOB_RECURSE SOURCE_IJKPLAYER ${ijkmedia}/ijkplayer/*.c ${ijkmedia}/ijkplayer/*.cpp)
file(GLOB_RECURSE SOURCE_SOUNDTOUCH ${ijkmedia}/ijksoundtouch/*.c)

# 排除苹果平台专属（.c 的 heic 等）与 libyuv 依赖
list(FILTER SOURCE_SDL EXCLUDE REGEX "/apple/")
list(FILTER SOURCE_SDL EXCLUDE REGEX "/abi_all/")
list(FILTER SOURCE_IJKPLAYER EXCLUDE REGEX "/apple/")
# 排除依赖 ffmpeg 内部头 http.h（安卓预编译 ffmpeg 未导出）的 HLS/segment
list(FILTER SOURCE_IJKPLAYER EXCLUDE REGEX "ijkhls")
list(FILTER SOURCE_IJKPLAYER EXCLUDE REGEX "ijksegment")

add_library(ijkplayer SHARED ${SOURCE_IJKJ4A} ${SOURCE_SDL} ${SOURCE_IJKPLAYER} ${SOURCE_SOUNDTOUCH})

set(FFMPEG_LIB ${FFMPEG_DIR}/lib)
add_library(ijkffmpeg-lib INTERFACE)
target_link_libraries(ijkffmpeg-lib INTERFACE
    ${FFMPEG_LIB}/libavdevice.a
    ${FFMPEG_LIB}/libavformat.a
    ${FFMPEG_LIB}/libavcodec.a
    ${FFMPEG_LIB}/libavfilter.a
    ${FFMPEG_LIB}/libswresample.a
    ${FFMPEG_LIB}/libswscale.a
    ${FFMPEG_LIB}/libavutil.a)

set(ASS_LIB       ${UNI_DIR}/ass/ass-${ARCH}/lib/libass.a)
set(FT_LIB        ${UNI_DIR}/freetype/freetype-${ARCH}/lib/libfreetype.a)
set(FRIBIDI_LIB   ${UNI_DIR}/fribidi/fribidi-${ARCH}/lib/libfribidi.a)
set(HARFBUZZ_LIB  ${UNI_DIR}/harfbuzz/harfbuzz-${ARCH}/lib/libharfbuzz.a)
set(UNIBREAK_LIB  ${UNI_DIR}/unibreak/unibreak-${ARCH}/lib/libunibreak.a)
set(OPENSSL_SSL   ${UNI_DIR}/openssl/openssl-${ARCH}/lib/libssl.a)
set(OPENSSL_CRYPTO ${UNI_DIR}/openssl/openssl-${ARCH}/lib/libcrypto.a)

# ffmpeg 编译时启用并链接的三方库（pkgconfig Libs 里列出的）
set(DAV1D_LIB     ${UNI_DIR}/dav1d/dav1d-${ARCH}/lib/libdav1d.a)
set(OPUS_LIB      ${UNI_DIR}/opus/opus-${ARCH}/lib/libopus.a)
set(UAVS3D_LIB    ${UNI_DIR}/uavs3d/uavs3d-${ARCH}/lib/libuavs3d.a)
set(XML2_LIB      ${UNI_DIR}/xml2/xml2-${ARCH}/lib/libxml2.a)
set(BLURAY_LIB    ${UNI_DIR}/bluray/bluray-${ARCH}/lib/libbluray.a)
set(DVDREAD_LIB   ${UNI_DIR}/dvdread/dvdread-${ARCH}/lib/libdvdread.a)
set(DVDNAV_LIB    ${UNI_DIR}/dvdnav/dvdnav-${ARCH}/lib/libdvdnav.a)
set(SMB2_LIB      ${UNI_DIR}/smb2/smb2-${ARCH}/lib/libsmb2.so)
set(FONTCONFIG_LIB ${UNI_DIR}/fontconfig/fontconfig-${ARCH}/lib/libfontconfig.a)

find_library(z-lib z REQUIRED)
find_library(log-lib log)
find_library(android-lib android)
find_library(vulkan-lib vulkan)
find_library(jnigraphics-lib jnigraphics)
find_library(m-lib m)
find_library(mediandk-lib mediandk)
find_library(dl-lib dl)

target_link_libraries(ijkplayer
    "-Wl,--start-group"
    ijkffmpeg-lib
    ${DAV1D_LIB}
    ${OPUS_LIB}
    ${UAVS3D_LIB}
    ${XML2_LIB}
    ${BLURAY_LIB}
    ${DVDREAD_LIB}
    ${DVDNAV_LIB}
    ${OPENSSL_SSL}
    ${OPENSSL_CRYPTO}
    ${ASS_LIB}
    ${FT_LIB}
    ${FRIBIDI_LIB}
    ${HARFBUZZ_LIB}
    ${UNIBREAK_LIB}
    ${FONTCONFIG_LIB}
    "-Wl,--end-group"
    ${SMB2_LIB}
    ${z-lib}
    ${dl-lib}
    ${mediandk-lib}
    ${log-lib}
    ${android-lib}
    ${vulkan-lib}
    ${jnigraphics-lib}
    ${m-lib}
    "-Wl,-z,max-page-size=16384"
    "-Wl,-Bsymbolic")
