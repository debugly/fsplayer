**简体中文**｜[English](doc/CONTRIBUTING_en-US.md)

# 贡献指南

感谢你对FSPlayer 的关注！这份指南会帮助你了解如何参与项目开发，和我一起为开源社区贡献一份力量。

## 开发环境配置

### 克隆仓库包括子模块

```bash
git clone --recurse-submodules https://github.com/debugly/fsplayer.git
cd fsplayer
```

### Apple xcframework

在 macOS 上安装好 Xcode 和 XcodeGen。

```bash
# 运行 iOS 端配套 App
./FFToolChain/main.sh install -p ios -l 'ass ffmpeg'
./generate-proj.sh
open ./examples/ios/FSPlayerDemo.xcworkspace

# 运行 macOS 端配套 App
./FFToolChain/main.sh install -p macos -l 'ass ffmpeg'
./generate-proj.sh
open ./examples/macos/AuraPlayer.xcworkspace

# 运行 tvOS 端配套 App
./FFToolChain/main.sh install -p tvos -l 'ass ffmpeg'
./generate-proj.sh
open ./examples/tvos/FSPlayerTVDemo.xcworkspace
```

### Android AAR 与 Aura APK

安装好 JDK 17、Android NDK `27.3.13750724`、CMake `3.22.1` 和 Android SDK Platform 35。

```bash
# 安装依赖库
./FFToolChain/main.sh install -p android -l 'ass yuv ffmpeg'

#打包 FSPlayer AAR
(cd ijkmedia/wrapper/android && ./gradlew :fsplayer:assembleRelease)

# 打包 Android 端配套App
(cd examples/android && ./gradlew :aura:assembleDebug)
```

## 分支与提交规范

本项目采用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 规范。

### Commit Message 格式

```
<type>: <简短描述>
```

常用 type：


| type       | 说明            |
| ---------- | ------------- |
| `feat`     | 新功能           |
| `fix`      | 修复 bug        |
| `docs`     | 文档变更          |
| `style`    | 格式调整（不影响代码逻辑） |
| `refactor` | 重构（既非新功能也非修复） |
| `perf`     | 性能优化          |
| `test`     | 添加或修改测试       |
| `chore`    | 构建、CI、依赖等杂项   |
| `ci`       | CI/CD 配置变更    |
| `revert`   | 回滚提交          |


### 分支命名

分支名应与 commit type 对应：`feat/描述`、`fix/描述`、`refactor/描述` 等。

示例：

- `feat/note-tagging` → 新功能分支
- `fix/startup-crash` → 修复分支

## Pull Request 流程

1. **先搜索** [已有 PR](https://github.com/debugly/fsplayer/pulls)，确认没有雷同的提交，避免重复劳动
2. Fork 本仓库，从 `当前开发分支` 创建你的功能/修复分支，不要从 main 分支创建
3. 开发完成后，确保本地编译没问题
4. 提交 PR 到 `当前开发分支`，**填写 PR 模板**中的各项内容

PR 标题同样遵循 Conventional Commits 格式，例如 `feat: 增加自动切换xx功能`。