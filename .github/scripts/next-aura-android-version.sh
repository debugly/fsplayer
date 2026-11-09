#!/usr/bin/env bash
# 输出 VERSION、VERSION_CODE、TAG 和 PREV_TAG，供 Aura APK workflow 使用。
set -euo pipefail

REPO="${1:-${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}}"
TAGS=$(gh api --paginate "repos/${REPO}/releases" --jq '.[] | select(.draft == false) | .tag_name')
PREV_VERSION=$(
  printf '%s\n' "$TAGS" |
    sed -nE 's|^Aura-android-([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' |
    sort -t. -k1,1n -k2,2n -k3,3n |
    tail -1
)

IFS=. read -r MAJOR MINOR PATCH <<< "${PREV_VERSION:-0.0.0}"
MAJOR=$((10#$MAJOR))
MINOR=$((10#$MINOR))
PATCH=$((10#$PATCH + 1))
VERSION="$MAJOR.$MINOR.$PATCH"
# 沿用 0.1.7 对应 107 的编码，让已安装的 APK 可以升级。
VERSION_CODE=$((MAJOR * 10000 + MINOR * 100 + PATCH))
printf 'VERSION=%s\nVERSION_CODE=%s\nTAG=Aura-android-%s\nPREV_TAG=%s\n' \
  "$VERSION" "$VERSION_CODE" "$VERSION" "${PREV_VERSION:+Aura-android-$PREV_VERSION}"
