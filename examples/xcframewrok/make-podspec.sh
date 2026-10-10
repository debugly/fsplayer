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

# 用 BASH_SOURCE 而不是 $0：$0 是调用者的路径，从别的目录调用时会算出错的
# THIS_DIR。原来那行 THIS_DIR=$(...cd "$THIS_DIR"...) 还自我引用，cd 的目标在赋值
# 完成前是空的，只能靠调用方恰好先 cd 到脚本目录才没出错。
THIS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

set -e
version=${1:-$(grep -m 1 VERSION_NAME= "$THIS_DIR/../../version.sh" | awk -F = '{printf "%s",$2}')}

# 输出到仓库根的 dist/，而不是脚本所在目录：发布流程把 dist/ 里的东西原样当
# release 资产，podspec 也放在那儿就不用在发布脚本里单独列一遍。
# 可选第二个参数可以指定别的输出目录，默认 <repo>/dist。
OUT_DIR=${2:-"$THIS_DIR/../../dist"}
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

cd "$THIS_DIR"

for plat in "" "-iOS" "-macOS" "-tvOS"; do
    template="template${plat}.spec.json"
    fn="FSPlayer${plat}.spec.json"
    if [[ -f "$template" ]]; then
        cat "$template" \
            | sed "s/__VERSION__/${version}/" \
            > "$OUT_DIR/${fn}"
        echo "Generated $OUT_DIR/${fn} (version: ${version})"
    fi
done
