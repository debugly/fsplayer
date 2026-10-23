#!/usr/bin/env bash
# 输出 VERSION / TAG / PREV_TAG，可直接追加到 GITHUB_ENV。
# 查询失败时停止；没有正式版本 tag 时从 0.0.1 开始。
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:-debugly/fsplayer}}"
TAGS=$(gh api --paginate "repos/${REPO}/git/matching-refs/tags/Aura-macos-" --jq '.[].ref')
PREV_VERSION=$(
  printf '%s\n' "$TAGS" |
    sed -nE 's|^refs/tags/Aura-macos-([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' |
    sort -t. -k1,1n -k2,2n -k3,3n |
    tail -1
)

IFS=. read -r MAJOR MINOR PATCH <<< "${PREV_VERSION:-0.0.0}"
VERSION="$((10#$MAJOR)).$((10#$MINOR)).$((10#$PATCH + 1))"
printf 'VERSION=%s\nTAG=Aura-macos-%s\nPREV_TAG=%s\n' \
  "$VERSION" "$VERSION" "${PREV_VERSION:+Aura-macos-$PREV_VERSION}"
