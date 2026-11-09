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

set -e

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
EXAMPLES_DIR="$REPO_ROOT/examples"
OUTPUT_DIR="$REPO_ROOT/build/xcframework"
FRAMEWORK=FSPlayer.framework

ios=("$EXAMPLES_DIR/ios/Release-iphoneos" "$EXAMPLES_DIR/ios/Release-iphonesimulator")
macos=("$EXAMPLES_DIR/macos/Release")
tvos=("$EXAMPLES_DIR/tvos/Release-appletvos" "$EXAMPLES_DIR/tvos/Release-appletvsimulator")

create_one_xcframework() {
    local output="$1"
    shift

    local dir framework
    local inputs=()
    for dir in "$@"; do
        framework="$dir/$FRAMEWORK"
        if [[ -d "$framework" ]]; then
            inputs+=(-framework "$framework")
            if [[ -d "$framework.dSYM" ]]; then
                inputs+=(-debug-symbols "$framework.dSYM")
            fi
        fi
    done
    if (( ${#inputs[@]} > 0 )); then
        rm -rf "$output"
        mkdir -p "$(dirname "$output")"
        xcodebuild -create-xcframework "${inputs[@]}" -output "$output"
    fi
}

case "${1:-all_and_platforms}" in
    all)
        create_one_xcframework "$OUTPUT_DIR/FSPlayer.xcframework" "${macos[@]}" "${ios[@]}" "${tvos[@]}"
        ;;
    ios)
        create_one_xcframework "$OUTPUT_DIR/ios/FSPlayer.xcframework" "${ios[@]}"
        ;;
    macos)
        create_one_xcframework "$OUTPUT_DIR/macos/FSPlayer.xcframework" "${macos[@]}"
        ;;
    tvos)
        create_one_xcframework "$OUTPUT_DIR/tvos/FSPlayer.xcframework" "${tvos[@]}"
        ;;
    *)
        create_one_xcframework "$OUTPUT_DIR/FSPlayer.xcframework" "${macos[@]}" "${ios[@]}" "${tvos[@]}"
        create_one_xcframework "$OUTPUT_DIR/ios/FSPlayer.xcframework" "${ios[@]}"
        create_one_xcframework "$OUTPUT_DIR/macos/FSPlayer.xcframework" "${macos[@]}"
        create_one_xcframework "$OUTPUT_DIR/tvos/FSPlayer.xcframework" "${tvos[@]}"
        ;;
esac
