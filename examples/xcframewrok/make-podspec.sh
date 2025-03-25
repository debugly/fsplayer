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
version=${1:-$(grep -m 1 VERSION_NAME= ../../version.sh | awk -F = '{printf "%s",$2}')}

fn=FSPlayer.spec.json
cat 'template.spec.json' \
    | sed "s/__VERSION__/${version}/" \
    > "${fn}"