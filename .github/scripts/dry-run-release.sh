#! /usr/bin/env bash
# 本地演练 fsplayer-release.yml：每次都编全部平台，看 dist/ 和 notes 分别是什么。
# 编译产物用假文件代替，真跑版本号计算、notes 生成和发布组装。
# 用法: dry-run-release.sh [beta]  —— 参数是 beta=true/false，默认 true
set -uo pipefail

BETA="${1:-true}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

rm -rf dist release-constants.env release-notes.md
mkdir -p /tmp/dryrun-bin
cat > /tmp/dryrun-bin/gh <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "release list")
    # 假装已有 beta-2 和一个正式版 tag
    printf '1.1.1-beta-2\n1.1.0\n'
    ;;
  "release create") echo "CREATE tag=$3" ;;
esac
exit 0
EOF
chmod +x /tmp/dryrun-bin/gh
export PATH=/tmp/dryrun-bin:$PATH
export GH_TOKEN=dry-run
export GITHUB_REF_NAME=dev-1.1.1
export ABIS=arm64-v8a,armeabi-v7a

echo "############################################################"
echo "# beta=$BETA"
echo "############################################################"

# ---- Download Pre Compiled Dependencies ----
PLATFORMS=(ios macos tvos android)
echo "[download] install 平台: ${PLATFORMS[*]}"

# ---- 编译（用假产物代替）----
mkdir -p dist
for n in FSPlayer FSPlayer-iOS FSPlayer-macOS FSPlayer-tvOS; do
  mkdir -p "dist/$n"; cp COPYING.LGPLv2.1 "dist/$n/LICENSE"; echo fake > "dist/$n/x"
  (cd "dist/$n" && zip -rq "../$n.zip" ./*); rm -rf "dist/$n"
done
cp COPYING.LGPLv2.1 dist/LICENSE
echo fake-aar > dist/fsplayer-release.aar

# ---- Determine Version ----
.github/scripts/prepare-release-version.sh "$BETA" >/dev/null
mv constants.env release-constants.env

# ---- Stamp Version Into Artifacts ----
( set -a; . release-constants.env; set +a; echo "  VERSION=$VERSION"
  ./examples/xcframewrok/make-podspec.sh "$VERSION" >/dev/null
  mv dist/fsplayer-release.aar "dist/fsplayer-${VERSION}.aar" )

# ---- Generate Release Notes ----
.github/scripts/generate-release-notes.sh release-constants.env release-notes.md >/dev/null

echo
echo "=== dist/ ==="
ls -1 dist/ | sed 's/^/  /'

echo
echo "=== Publish Release ==="
set -a; . release-constants.env; set +a
shopt -s nullglob
ASSETS=(dist/*)
shopt -u nullglob
echo "  资产 ${#ASSETS[@]} 个: ${ASSETS[*]}"
echo
echo "--------- 最终 release notes ---------"
cat release-notes.md
echo "------------------------------------"

rm -rf dist release-constants.env release-notes.md /tmp/dryrun-bin
