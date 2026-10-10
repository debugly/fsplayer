#!/bin/sh

set -e

cd "$(dirname "$0")"

VERSION_NAME=1.1.2
VERSION_TARGET=$1

echo "alter version to $VERSION_NAME"

# 版本号只匹配数字和点，用来保证不会误伤别处同样形状的字符串。
V='[[:digit:]][[:digit:].]*'

# README（两种语言）：CocoaPods 的 podspec 下载地址，和 Maven 坐标。
# 中文版必须一起改——只 sed 英文 README 的话，中文用户照抄会拿到上一版的
# 下载地址。
do_version_readme() {
    for f in README.md README_zh-CN.md; do
        sed -i "" \
            -e "s#\(releases/download/\)$V\(/FSPlayer\.spec\.json\)#\1$VERSION_NAME\2#g" \
            -e "s#\(io\.github\.debugly:fsplayer:\)$V#\1$VERSION_NAME#g" \
            "$f"
    done
}

# Xcode 工程：FSPlayer.yml 是 xcodegen 的输入，xcodeproj 是它的产物，
# 所以改完 yml 必须重新生成，否则构建用的还是旧版本号。
do_version_xcode() {
    sed -i "" "s/\([[:space:]]*MARKETING_VERSION:[[:space:]]*\)$V/\1$VERSION_NAME/g" FSPlayer.yml
    ./generate-proj.sh
}

# Android：build.gradle 里的 fsPublishVersion 只是本地兜底值，CI 发布时用
# -PversionName 传入真实版本覆盖它。这里跟着改是为了本地 publishToMavenLocal
# 不会撞上一个已经发布过的坐标。
do_version_android() {
    sed -i "" \
        -e "s#\(findProperty('versionName') ?: '\)$V#\1$VERSION_NAME#g" \
        -e "s#\(version\.sh 读），本地默认 \)$V#\1$VERSION_NAME#g" \
        android/fsplayer/build.gradle
}

if [ "$VERSION_TARGET" = "readme" ]; then
    do_version_readme
elif [ "$VERSION_TARGET" = "xcode" ]; then
    do_version_xcode
elif [ "$VERSION_TARGET" = "android" ]; then
    do_version_android
elif [ "$VERSION_TARGET" = "show" ]; then
    echo $VERSION_NAME
else
    do_version_readme
    do_version_xcode
    do_version_android
fi
