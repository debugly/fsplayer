#!/usr/bin/env bash
# 算出下一个 beta 序号。
#
# 用法: next-beta-version.sh <base_version>
#   base_version  例如 1.1.1
#
# 查 GitHub 上已有的 <base>-beta-<N> release tag，取最大的 N 加一；一个都没有
# 就从 1 开始。用最大值而不是取最后一个，保证 beta-1 和 beta-3 同时存在时
# 下一个是 beta-4 而不是 beta-2（tag 被删过就会留缺口）。
#
# 序号让每个 beta 都是一个全新的 Maven 坐标：Central 只禁止同坐标覆盖，而
# 1.1.1-beta-1 / 1.1.1-beta-2 / 1.1.1 互不相同，所以 beta 也能发 Central。
set -uo pipefail

BASE_VERSION="$1"
PREFIX="${BASE_VERSION}-beta-"

# gh 查询必须成功，否则序号会退回 1 并和已有 release 撞名——CI 里就因为这步
# 缺 GH_TOKEN 而连着两次都用 beta-1 覆盖同一个 release。所以这里不做兜底：
# 拿不到列表就直接失败，让问题当场暴露。
TAGS=$(gh release list --limit 200 --json tagName -q '.[].tagName') || {
  echo "error: gh release list 失败，无法计算下一个 beta 序号" >&2
  exit 1
}

# 前缀里带上了 BASE_VERSION，所以 1.1.1-beta- 不会命中 1.1.2-beta-9 或
# 1.1.11-beta-50；末尾的 '-beta-' 让版本号边界成立。
#
# BASE_VERSION 来自 version.sh 而不是命令行，但仍然转义：正则元字符（version.sh
# 里写成 1.1.x 之类）会让前缀匹配到意料之外的 tag。
ESCAPED_PREFIX=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$()+?{|]/\\&/g')
MAX_BETA="$(
  printf '%s\n' "$TAGS" |
    sed -n "s|^${ESCAPED_PREFIX}\\([0-9][0-9]*\\)\$|\\1|p" |
    sort -n |
    tail -1 || true
)"

echo $(( ${MAX_BETA:-0} + 1 ))
