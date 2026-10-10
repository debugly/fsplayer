#!/usr/bin/env bash
# 算出下一个 beta 序号。
#
# 用法: next-beta-version.sh <base_version> <edition>
#   base_version  例如 1.1.1
#   edition       master/main 会传 "beta"，其它分支传分支名
#
# 查 GitHub 上已有的 <base>-<edition>-<N> release tag，取最大的 N 加一；
# 一个都没有就从 1 开始。用最大值而不是取最后一个，保证 beta-1 和 beta-3
# 同时存在时下一个是 beta-4 而不是 beta-2（tag 被删过就会留缺口）。
#
# 自增序号是为了让每个 beta 都是一个全新的 Maven 坐标：Central 只禁止同坐标
# 覆盖，而 1.1.1-beta-1 / -beta-2 / 1.1.1 互不相同，所以 beta 也能发 Central。
set -uo pipefail

BASE_VERSION="$1"
EDITION="$2"
PREFIX="${BASE_VERSION}-${EDITION}-"

# 序号限长 6 位。这不是随意挑的：旧格式的时间戳 tag 是 1.1.1-dev-1.1.1-<14位>，
# 分隔符换成 '-' 之后它们同样以「前缀 + 纯数字」结尾，字面匹配无法排除。
# 限定位数才能把它们挡在外面（6 位够用到 beta-999999）。
#
# PREFIX 里的正则元字符也必须转义：edition 是分支名，dev-1.1.1 的 '.' 在正则中
# 会匹配任意字符。
#
# 前缀里带上了 BASE_VERSION，所以 1.1.1-beta- 不会命中 1.1.2-beta-9 或
# 1.1.11-beta-50；末尾的 '-' 同时充当版本号边界。
#
# || true 是必须的：第一次跑时一条 tag 都匹配不到，管道会返回 1，
# 在 pipefail 下会让脚本提前打断。
ESCAPED_PREFIX=$(printf '%s' "$PREFIX" | sed 's/[][\.*^$()+?{|]/\\&/g')
MAX_BETA="$(
  gh release list --limit 200 --json tagName -q '.[].tagName' |
    sed -n "s|^${ESCAPED_PREFIX}\\([0-9][0-9]\\{0,5\\}\\)\$|\\1|p" |
    sort -n |
    tail -1 || true
)"

echo $(( ${MAX_BETA:-0} + 1 ))