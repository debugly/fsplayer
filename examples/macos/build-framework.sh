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

if [[ ! -d Pods/FSPlayer.xcodeproj ]]; then
    echo "pod install"
    pod install
fi

# 1
WORKSPACE_NAME="FSPlayerMacDemo.xcworkspace"
TARGET_NAME="FSPlayer"
WORK_DIR="Pods/Release/${TARGET_NAME}"

# 2
if [ -d ${WORK_DIR} ]; then
    rm -rf ${WORK_DIR}
fi

# 3
# xcodebuild -showsdks
# Build the framework for device and simulator with all architectures.
export MACOSX_DEPLOYMENT_TARGET=10.11

xcodebuild -workspace ${WORKSPACE_NAME} -scheme ${TARGET_NAME} \
-configuration Release  \
-destination 'generic/platform=macOS' \
BUILD_DIR=. \
clean build

echo "framework dir: ${WORK_DIR}"