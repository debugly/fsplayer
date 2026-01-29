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
    ../../generate-proj.sh
fi

# 1
PROJECT_NAME="FSPlayer.xcodeproj"
TARGET_NAME="FSPlayer-macOS"

WORK_DIR="Release"

# 2
if [ -d ${WORK_DIR} ]; then
    rm -rf ${WORK_DIR}
fi

# 3
# project方式
# xcodebuild -showsdks
# Build the framework for device and simulator with all architectures.

xcodebuild -project ${PROJECT_NAME} -target ${TARGET_NAME} \
-configuration Release  \
-sdk macosx -arch x86_64 -arch arm64 \
BUILD_DIR="$THIS_DIR" \
clean build

echo "macos framework dir:$WORK_DIR"