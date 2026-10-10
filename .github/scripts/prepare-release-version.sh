#!/usr/bin/env bash
# 算出这次发布的版本号和 tag，写进 constants.env（调用方会 mv 成 release-constants.env）。
#
# 用法: prepare-release-version.sh <beta>
#   beta  true / false —— true 时版本带自增序号，false 时是裸版本号
#
# 一次发布包含全部平台，产物和说明挂在同一个 release 上，所以只有一个版本号：
# beta 的 tag 是 <base>-beta-<N>，例如 1.1.1-beta-1；正式版是裸版本号，例如 1.1.1。
#
# 版本号里不再带平台段。带平台段是分平台发布时代的产物，那时 android 和 apple
# 各发各的 release，tag 必须能区分开；现在两边合进同一个 release，多一个平台段
# 只会让 podspec 里的 releases/download/<version>/ 链接和实际 tag 对不上。
set -euo pipefail

BETA="$1"
BASE_VERSION=$(grep -m 1 VERSION_NAME= version.sh | cut -d= -f2)

if [[ "$BETA" == "true" ]]; then
  BETA_NO=$(.github/scripts/next-beta-version.sh "$BASE_VERSION")
  VERSION="${BASE_VERSION}-beta-${BETA_NO}"
else
  VERSION="$BASE_VERSION"
fi

# 值用单引号包起来：版本号不含空格，但 source 会把未加引号的空格当命令分隔符，
# 加引号后即使以后版本号规则变了（含空格等）也不会被拆开。
{
  echo "BASE_VERSION='$BASE_VERSION'"
  echo "VERSION='$VERSION'"
  echo "TAG='$VERSION'"
} > constants.env

# 同时写进 GITHUB_ENV：workflow 里每一步都是独立的 shell，export 不会跨步骤传播，
# 打包和发布那几步要靠 GITHUB_ENV 才能读到 VERSION。
if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "BASE_VERSION=$BASE_VERSION"
    echo "VERSION=$VERSION"
    echo "TAG=$VERSION"
  } >> "$GITHUB_ENV"
fi

cat constants.env
