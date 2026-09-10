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

FMN="FSPlayer"

function get_inputs_with_path()
{
    fmwk="${1}/$FMN.framework"
    inputs=""
    if [[ -d $fmwk ]]; then
        inputs="$inputs -framework $fmwk"
    fi
    fmwk_dsym="${fmwk}.dSYM"
    if [[ -d $fmwk_dsym ]]; then
        inputs="$inputs -debug-symbols $(cd $fmwk_dsym; DIRNAME=$(dirname pwd); cd "$DIRNAME"; pwd)"
    fi
    echo "$inputs"
}

function get_macos_inputs()
{
    get_inputs_with_path 'macos/Release'
}

function get_ios_inputs()
{
    echo "$(get_inputs_with_path 'ios/Release-iphoneos') $(get_inputs_with_path 'ios/Release-iphonesimulator')"
}

function get_tvos_inputs()
{
    echo "$(get_inputs_with_path 'tvos/Release-appletvos') $(get_inputs_with_path 'tvos/Release-appletvsimulator')"
}

function get_inputs()
{
    echo "$(get_macos_inputs) $(get_ios_inputs) $(get_tvos_inputs)"
}

function create_one_xcframework() {
    local inputs="$1"
    local output="$2"
    inputs="$(echo $inputs | xargs)"
    if [[ -n "$inputs" ]]; then
        rm -rf "$output"
        mkdir -p "$(dirname "$output")"
        xcodebuild -create-xcframework $inputs -output "$output"
    fi
}

function do_make_xcframework() {
    cd ..
    local XC_XCFRMK_DIR='xcframewrok'
    local target="${1:-all_and_platforms}"

    case "$target" in
        'all')
            create_one_xcframework "$(get_inputs)" "$XC_XCFRMK_DIR/${FMN}.xcframework"
            ;;
        'ios')
            create_one_xcframework "$(get_ios_inputs)" "$XC_XCFRMK_DIR/ios/${FMN}.xcframework"
            ;;
        'macos')
            create_one_xcframework "$(get_macos_inputs)" "$XC_XCFRMK_DIR/macos/${FMN}.xcframework"
            ;;
        'tvos')
            create_one_xcframework "$(get_tvos_inputs)" "$XC_XCFRMK_DIR/tvos/${FMN}.xcframework"
            ;;
        *)
            create_one_xcframework "$(get_inputs)" "$XC_XCFRMK_DIR/${FMN}.xcframework"
            create_one_xcframework "$(get_ios_inputs)" "$XC_XCFRMK_DIR/ios/${FMN}.xcframework"
            create_one_xcframework "$(get_macos_inputs)" "$XC_XCFRMK_DIR/macos/${FMN}.xcframework"
            create_one_xcframework "$(get_tvos_inputs)" "$XC_XCFRMK_DIR/tvos/${FMN}.xcframework"
            ;;
    esac
}

do_make_xcframework "$1"