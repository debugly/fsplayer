#!/usr/bin/env bash
# 生成这次发布的说明，写进 release-notes.md。内容包含 Apple 和 Android 两个部分。
#
# 用法: generate-release-notes.sh <env-file> <out-file>
#   env-file prepare-release-version.sh 产出的版本号文件
#   out-file 输出路径
#
# 一次发布包含全部平台，release 只有一份说明，所以这里一次写出两个部分
# （Apple 在前、Android 在后），不再各写一个文件再拼接。
set -euo pipefail

ENV_FILE="$1"
OUT="$2"

VERSION=$(grep -E "^VERSION=" "$ENV_FILE" | cut -d= -f2- | tr -d "'\"")
TAG=$(grep -E "^TAG=" "$ENV_FILE" | cut -d= -f2- | tr -d "'\"")
BASE_VERSION=$(grep -E "^BASE_VERSION=" "$ENV_FILE" | cut -d= -f2- | tr -d "'\"")
if [[ -z "$VERSION" || -z "$TAG" || -z "$BASE_VERSION" ]]; then
  echo "::error::$ENV_FILE 里缺少 VERSION / TAG / BASE_VERSION，先跑 prepare-release-version.sh" >&2
  exit 1
fi

# 上一个正式版 tag，用来生成 Changelog 的 compare 链接。只收纯 semver 的 tag，
# 按版本降序取第一个 —— beta tag 本身不是纯 semver，不在列表里。
# 一个都没有就退回 HEAD~1，避免链接指向不存在的对比。
PREV_TAG=$(git tag --list --sort=-v:refname \
  | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" \
  | sed -n '1p')
if [[ -z "$PREV_TAG" ]]; then
  echo "::warning::没有任何正式版 tag，Changelog 退回与上一个提交的对比"
  PREV_TAG="HEAD~1"
fi

# 读 FFmpeg 实际是什么许可，写进 release 说明。
#
# 从 config.h 的 FFMPEG_LICENSE 读实际值，而不是写死LGPL-2.1——写死的话，
# configure 参数一旦变了（比如有人加了 --enable-gpl），说明会继续声称是 LGPL，
# 那才是真正的许可事故。CONFIG_GPL / CONFIG_NONFREE 被打开时也在说明里点出来，
# 不中断构建：FFToolChain 用什么参数编是上游的决定，发布流程只负责如实记录。
#
# 用法: ffmpeg_license <platform-dir>
ffmpeg_license() {
  local base="$1"
  local cfg
  # 每个 ABI 一份 config.h，内容一致，取第一份即可。
  cfg=$(find "$base" -path '*/include/libffmpeg/config.h' -type f | sort | head -1)
  if [[ -z "$cfg" ]]; then
    echo "::warning::${base} 下找不到 config.h，许可一栏按 LGPL-2.1-or-later 记录（未经核实）" >&2
    printf 'LGPL-2.1-or-later (unverified)'
    return 0
  fi

  local license
  license=$(sed -n 's/^#define FFMPEG_LICENSE \(.*\)$/\1/p' "$cfg" | head -1 | tr -d '"')
  if [[ -z "$license" ]]; then
    echo "::warning::${cfg} 里没有 FFMPEG_LICENSE，许可一栏按 LGPL-2.1-or-later 记录（未经核实）" >&2
    printf 'LGPL-2.1-or-later (unverified)'
    return 0
  fi

  # config.h 里写的是 "LGPL version 2.1 or later"，说明里用 SPDX 写法。
  local spdx
  case "$license" in
    *"LGPL"*) spdx="LGPL-2.1-or-later" ;;
    *)        spdx="$license" ;;
  esac

  # GPL / nonfree 会改变整个产物的许可，光写 LGPL 会误导下游，所以明确标出来。
  # 不中断构建：FFToolChain 用什么参数编是上游的决定，这里只负责如实记录。
  if grep -qE '^#define CONFIG_(GPL|NONFREE) 1' "$cfg"; then
    echo "::warning::$(basename "$(dirname "$(dirname "$(dirname "$cfg")")")") 里CONFIG_GPL/CONFIG_NONFREE 被打开了，产物不是纯 LGPL，发布说明里已注明" >&2
    printf '%s, plus --enable-gpl/--enable-nonfree' "$spdx"
    return 0
  fi

  printf '%s' "$spdx"
}

# FFTmpeg 的版本号，从 configs/libs/ffmpeg.sh 里读。那个文件是滚动别名（当前指向
# 8.1.2），升级 FFmpeg 时它会跟着改，这里读到的版本也就自动跟着变。
ffmpeg_version() {
  local cfg="FFToolChain/configs/libs/ffmpeg.sh"
  local v
  v=$(sed -n "s/^export GIT_REPO_VERSION=//p" "$cfg" | head -1 | tr -d "'\"")
  if [[ -z "$v" ]]; then
    echo "::error::无法从 ${cfg} 读取 FFmpeg 版本" >&2
    return 1
  fi
  printf 'FFmpeg %s' "$v"
}

# 从 FFToolChain 的产物目录里读出实际参与构建的三方库，而不是写死一份清单。
# install -l 'ass ffmpeg' 只会拉 ffmpeg 真正依赖的库，所以这个目录就是这次发布
# 的确切内容。目录不存在或为空都要失败：静默发一条空的 third-party 比没有更糟。
#
# list_lib_names 输出原始目录名（一行一个，排序后），join_names 负责拼成顿号串。
# 用法: list_lib_names <platform-dir>
list_lib_names() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "::error::找不到 ${dir}，无法列出三方库" >&2
    return 1
  fi

  # __MACOSX 是 macOS 压缩时产生的元数据目录，不是库。
  find "$dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
    | grep -v '^__MACOSX$' \
    | LC_ALL=C sort
}

# 用数组 join 而不是 out="${out:+$out、}$n"：bash 会把 ${out:...} 里的「out、」
# 整体当变量名，全角顿号被吞掉，结果只剩最后一个库。
join_names() {
  local out=() n
  while IFS= read -r n; do
    # ffmpeg 目录换成带版本号的名字，具体版本从配置里读
    if [[ "$n" == "ffmpeg" ]]; then
      n=$(ffmpeg_version) || return 1
    fi
    out+=("$n")
  done <<< "$1"
  local IFS=、
  printf '%s' "${out[*]}"
}

# Apple 侧的 third-party 行。
# 三个平台装的依赖常常一致，那就一行写完；但 install 是按平台分别跑的，依赖可能
# 不一样（比如只有 iOS 需要某个库）。所以先比对：三个目录相同就一行输出，不同就
# 每个平台一行——合并去重会列出这个 xcframework 里根本没用到的库，比写错更糟。
list_third_party_apple() {
  local base="FFToolChain/build/product"
  local ios="" macos="" tvos=""

  local dir names
  for dir in ios macos tvos; do
    names=$(list_lib_names "$base/$dir/universal") || return 1
    if [[ "$dir" == "ios" ]]; then ios="$names"
    elif [[ "$dir" == "macos" ]]; then macos="$names"
    else tvos="$names"; fi
  done

  # join_names 可能因为读不到 FFmpeg 版本而失败，先算进变量再判断，不要留在
  # printf 的参数里——那样非零退出码传不出去。
  local merged ios_tp macos_tp tvos_tp
  merged=$(join_names "$(printf '%s\n' "$ios" "$macos" "$tvos" | LC_ALL=C sort -u)") || return 1
  if [[ "$ios" == "$macos" && "$macos" == "$tvos" ]]; then
    printf -- '- third-party: %s' "$merged"
  else
    ios_tp=$(join_names "$ios") || return 1
    macos_tp=$(join_names "$macos") || return 1
    tvos_tp=$(join_names "$tvos") || return 1
    printf -- '- iOS third-party: %s\n- macOS third-party: %s\n- tvOS third-party: %s' \
      "$ios_tp" "$macos_tp" "$tvos_tp"
  fi
}

# Android AAR 那一段。写到 stdout，调用方追加进最终文件。
android_section() {
  # 坐标从 build.gradle 里读，不写死：groupId 和 artifactId 都在那里定义，改了之后
  # 这里会自动跟上。解析失败直接失败，不发空坐标的说明。
  local artifact_id group_id
  artifact_id=$(sed -n "s/.*coordinates(fsPublishGroupId, '\([^']*\)'.*/\1/p" \
    android/fsplayer/build.gradle | head -1)
  group_id=$(sed -n "s/.*findProperty('publishGroupId') ?: '\([^']*\)'.*/\1/p" \
    android/fsplayer/build.gradle | head -1)
  if [[ -z "$artifact_id" || -z "$group_id" ]]; then
    echo "::error::无法从 android/fsplayer/build.gradle 解析出 Maven 坐标" >&2
    return 1
  fi

  local third_party license
  third_party=$(list_lib_names FFToolChain/build/product/android/universal) || return 1
  third_party=$(join_names "$third_party") || return 1
  license=$(ffmpeg_license FFToolChain/build/product/android/universal)

  cat <<EOF
## Android AAR

- ABIs: ${ABIS}
- Changelog: [${PREV_TAG}...${TAG}](https://github.com/debugly/fsplayer/compare/${PREV_TAG}...${TAG})
- license: ${license}
- note: the library (namespace com.debugly.fsplayer), FFmpeg statically linked into libfsplayer.so, libsmb2.so shipped alongside
- third-party: ${third_party}

### Gradle

\`\`\`
repositories { mavenCentral() }
dependencies { implementation '${group_id}:${artifact_id}:${VERSION}' }
\`\`\`

### Maven

\`\`\`xml
<dependency>
  <groupId>${group_id}</groupId>
  <artifactId>${artifact_id}</artifactId>
  <version>${VERSION}</version>
</dependency>
\`\`\`
EOF
}

# Apple xcframeworks 那一段。同样写到 stdout。
apple_section() {
  local third_party license
  third_party=$(list_third_party_apple) || return 1
  # 三个平台的 config.h 内容一致，取 iOS 那份即可。
  license=$(ffmpeg_license FFToolChain/build/product/ios/universal)

  cat <<EOF
## Apple xcframeworks

- platforms: iOS 12+, macOS 10.14+, tvOS 12+
- Changelog: [${PREV_TAG}...${TAG}](https://github.com/debugly/fsplayer/compare/${PREV_TAG}...${TAG})
- license: ${license}
- note: Objective-C framework, FFmpeg statically linked
${third_party}

### CocoaPods

\`\`\`ruby
pod "FSPlayer", :podspec => 'https://github.com/debugly/fsplayer/releases/download/${TAG}/FSPlayer.spec.json'
\`\`\`
EOF
}

# CHANGELOG 里当前版本号那一段，Apple 和 Android 共用，所以放在两个平台段落前面。
#
# 按 BASE_VERSION 匹配而不是 VERSION：beta 的 VERSION 是 1.1.1-beta-3，但 CHANGELOG
# 记的是 1.1.1（同一批改动在 beta 和正式版下是同一段），而且 beta 之间也不该各写
# 一段重复的 changelog。找不到对应小节就不输出任何内容——还没有为这个版本整理过
# changelog 时，说明里少一段比留个空标题好。
changelog_section() {
  local section
  # sed 打印的是闭区间：从 '## tag <base>' 行开始，到下一个 '## ' 标题行为止（含）。
  # 小节正文里不会有 '## ' 标题，所以这个边界是可靠的。
  section=$(sed -n "/^## tag ${BASE_VERSION}\$/,/^## /p" CHANGELOG.md)

  # sed 匹配不到时退出码是 0，所以不能靠退出码判断有没有这一段。
  if [[ -z "$section" ]]; then
    echo "::notice::CHANGELOG.md 里没有 tag ${BASE_VERSION} 的一段，跳过 changelog" >&2
    return 0
  fi

  # 去掉尾部那行下一个小节的标题（sed 范围包含它），否则会多出一个空标题。
  section=$(printf '%s\n' "$section" | sed '$d')

  # 去掉段首的 '## tag 1.1.1' 标题行：release 页面顶部已经有 'FSPlayer <tag>'
  # 大标题，再放一个版本号标题是重复的。正文直接跟在 '## What's Changed' 下。
  # 如果正文里还有 '## ' 小标题，降一级成 '### '，让整份说明只有一层二级标题
  # （What's Changed / Apple / Android）。
  #
  # '/./,$!d' 删掉开头的连续空行：CHANGELOG 里标题和第一条之间本来有空行，
  # 不去掉的话 '## What's Changed' 下面会连着两个空行。
  section=$(printf '%s\n' "$section" | tail -n +2 | sed -e 's/^## /### /' -e '/./,$!d')
  [[ -n "$section" ]] || return 0

  # 记录已输出，供组装时空出与下一段之间的空行。没有这一段时不能留行首空行。
  CHANGELOG_EMITTED=1
  printf '## What'"'"'s Changed\n\n%s\n' "$section"
}

# 两个函数都直接输出而不是写文件，所以 set -e 能管到失败：任一环节出错
# （读不到 third-party、FFmpeg 版本、Maven 坐标）都会停在这里，不会发出半份说明。
# 组装顺序：changelog 在最前（两个平台共用的改动），Apple 和 Android 各一段。
{
  CHANGELOG_EMITTED=
  changelog_section
  [[ -z "$CHANGELOG_EMITTED" ]] || echo
  apple_section
  echo
  android_section
} > "$OUT"

echo "generated $OUT"