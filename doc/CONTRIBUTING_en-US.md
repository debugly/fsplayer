[简体中文](../CONTRIBUTING.md) · **English**

# Contributing to FSPlayer

Thanks for your interest in FSPlayer. This guide covers setting up your development environment and submitting changes.

## Development setup

### Clone the repository with its submodules

```bash
git clone --recurse-submodules https://github.com/debugly/fsplayer.git
cd fsplayer
```

### Apple XCFramework

Install Xcode and XcodeGen on macOS.

```bash
# Run the iOS sample app
./FFToolChain/main.sh install -p ios -l 'ass ffmpeg'
./generate-proj.sh
open ./examples/ios/FSPlayerDemo.xcworkspace

# Run the macOS sample app
./FFToolChain/main.sh install -p macos -l 'ass ffmpeg'
./generate-proj.sh
open ./examples/macos/AuraPlayer.xcworkspace

# Run the tvOS sample app
./FFToolChain/main.sh install -p tvos -l 'ass ffmpeg'
./generate-proj.sh
open ./examples/tvos/FSPlayerTVDemo.xcworkspace
```

### Android AAR and Aura APK

Install JDK 17, Android NDK `27.3.13750724`, CMake `3.22.1`, and Android SDK Platform 35.

```bash
# Install the native dependencies
./FFToolChain/main.sh install -p android -l 'ass yuv ffmpeg'

# Build the FSPlayer AAR
(cd ijkmedia/wrapper/android && ./gradlew :fsplayer:assembleRelease)

# Build the Android sample app
(cd examples/android && ./gradlew :aura:assembleDebug)
```

## Branch and commit conventions

This project follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

### Commit message format

```text
<type>: <short description>
```

| Type | Use |
| --- | --- |
| `feat` | Add a feature |
| `fix` | Fix a bug |
| `docs` | Update documentation |
| `style` | Change formatting without altering behavior |
| `refactor` | Restructure existing code without adding features or fixing bugs |
| `perf` | Improve performance |
| `test` | Add or update tests |
| `chore` | Maintain build tooling, CI, or dependencies |
| `ci` | Update CI/CD configuration |
| `revert` | Revert a commit |

### Branch naming

Use the corresponding commit type as your branch prefix, such as `feat/`, `fix/`, or `refactor/`.

- `feat/note-tagging` for a new feature
- `fix/startup-crash` for a bug fix

## Pull request process

1. Search [existing pull requests](https://github.com/debugly/fsplayer/pulls) to avoid duplicating work.
2. Fork the repository and create your branch from the current development branch. Use that branch as your base instead of `main`.
3. Verify that your changes build locally.
4. Open a pull request against the current development branch and complete each section of the PR template.

Use the Conventional Commits format for PR titles as well. For example, `feat: add automatic switching`.
