#! /usr/bin/env bash
#
# Copyright (C) 2024 Matt Reach<qianlongxu@gmail.com>

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

THIS_DIR=$(DIRNAME=$(dirname "$0"); cd "$DIRNAME"; pwd)
cd "$THIS_DIR"

set -e

if [[ ! -d FSPlayer.xcodeproj ]]; then
    ./generate-fsplayer.sh
fi

# 1
PROJECT_NAME="FSPlayer.xcodeproj"
TARGET_NAME="FSPlayer-tvOS"

WORK_DIR="Release-appletvos"
SIM_WORK_DIR="Release-appletvsimulator"

# 2
if [ -d ${WORK_DIR} ]; then
    rm -rf ${WORK_DIR}
fi

if [ -d ${SIM_WORK_DIR} ]; then
    rm -rf ${SIM_WORK_DIR}
fi

# 3
# project方式
# xcodebuild -showsdks
# Build the framework for device and simulator with all architectures.
export IPHONEOS_DEPLOYMENT_TARGET=11.0

xcodebuild -project ${PROJECT_NAME} -target ${TARGET_NAME} \
-configuration Release  \
-sdk appletvsimulator -arch x86_64 -arch arm64 \
BUILD_DIR=. \
clean build

xcodebuild -project ${PROJECT_NAME} -target ${TARGET_NAME} \
-configuration Release  \
-sdk appletvos -arch arm64 \
BUILD_DIR=. \
clean build

echo "tvos framework dir:$WORK_DIR"
echo "tvos simulator framework dir: $SIM_WORK_DIR"