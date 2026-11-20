# Issue #5 YouTube 播放亮度偏高

## Chrome 验收场景 1:14

Chrome 157 与 AuraPlayer 暂停在同一份 4K VP9 Profile 2 MP4 的 1:14 附近。该轨为限幅 BT.2020/PQ，封装携带 1000 nit 母版显示元数据。在 Chrome 中天空保留蓝色，旧版 AuraPlayer 的同一区域接近纯白。

从原 MP4 抽取 1:14 的一帧，在同一块内建 Retina 屏幕上把同一份 P010 样本送到四个显示层。测量时屏幕 EDR headroom 为 2.0。系统参考栏使用携带相同 PQ 色彩标记的 AVSampleBufferDisplayLayer。Chromium 的 macOS 视频合成支持这种系统视频层，并会传递 PQ 和 HDR10 元数据。 [Chromium macOS 视频合成源码](https://chromium.googlesource.com/chromium/src/+/master/ui/accelerated_widget_mac/ca_renderer_layer_tree.mm)

| 区域 | 旧版 EDR | 仅 HDR10 色调映射 | HDR10 色调映射 + BT.2020 | 系统视频层 |
| --- | --- | --- | --- | --- |
| 天空 | 255, 255, 255 | 170, 225, 243 | 171, 226, 243 | 169, 224, 243 |
| 蓝衣 | 10, 90, 118 | 33, 78, 103 | 5, 76, 100 | 10, 80, 103 |
| 肤色 | 134, 87, 60 | 110, 71, 49 | 119, 78, 53 | 120, 79, 55 |

上表是同屏截图中相同位置的小区域 RGB 均值。数值受截图编码及缩放影响。该对照使用 Core Animation 的 HDR10 默认参数，以便单独测量启用色调映射和保留色域的效果。

旧版 Metal 层启用了 EDR，但 EDRMetadata 为空。Core Animation 在这种配置下可以直接裁掉高于显示器 headroom 的分量。传入 HDR10 元数据后，系统会根据显示器做色调映射。让 shader 输出线性 BT.2020，并将层设为相同的色彩空间，能进一步减少饱和色和肤色的差异。Shader 与 CAEDRMetadata 都以 203 nit 为归一化基准。 [Apple CAMetalLayer EDRMetadata](https://developer.apple.com/documentation/quartzcore/cametallayer/edrmetadata)

修复把解码帧的母版显示信息和内容亮度信息转成 Core Video 附件，在 PQ 直出时启用系统色调映射。缺少静态元数据时使用 Core Animation 默认值。验证完整编译了 macOS 的 FSPlayer 和 AuraPlayer，并用编译后的框架测试了 HDR10 附件的编码、复用、缺失回退以及切换到 HLG 和 SDR 后清除旧的元数据。

在正式编译出的 AuraPlayer 5-youtube 中打开原 MP4，暂停在 1:14 后复查。相对于本轮开始时记录的 Chrome 画面，修复版恢复了天空的蓝色与左侧木板的高光纹理，蓝衣和肤色也明显接近。两个播放窗口的时间显示精确到秒，表中的像素数据来自逐帧锁定的同屏探针。

## Metal 显示模式

| `FSHDRDisplayMode` | 实际用途 | `CAMetalLayer.colorspace` |
| --- | --- | --- |
| `FSHDRDisplayModeSDR` | 输出到 `BGRA8Unorm`。SDR 输入直接输出，HDR 输入由 shader 做 HDR → SDR 色调映射。 | `nil` |
| `FSHDRDisplayModeLinearSRGB` | 输出线性 sRGB 到 `RGBA16Float` EDR 图层。目前用于 HLG 等沿用原有直出路径的内容。 | `kCGColorSpaceExtendedLinearSRGB` |
| `FSHDRDisplayModeLinearBT2020` | HDR10/PQ 直出。保留线性 BT.2020，输出到 `RGBA16Float` EDR 图层，并通过 `EDRMetadata` 交给 Core Animation 做色调映射。 | `kCGColorSpaceExtendedLinearITUR_2020` |

## 早期亮度范围排查

[GitHub issue](https://github.com/debugly/fsplayer/issues/5) 的原视频在 34.2 秒处可复现偏亮。造成 HDR 和 SDR 同时偏亮的原因之一是 Apple 软件解码路径丢失了 Y′CbCr 范围。YouTube 的 SDR 轨 `243` 是 8 位 BT.709，HDR 轨 `332` 是 10 位 BT.2020/PQ，两个轨都由 FFmpeg 标记为有限范围（`tv`）。

## 同帧对照

在 Apple Silicon Mac 上，分别把两个轨的同一帧送入软件解码使用的 CVPixelBuffer 池和 FSPlayer 的 Metal 渲染器，再从离屏纹理读回像素。分支基线是 `5b479ebc`。SDR 参考用 FFmpeg 按 BT.709 和有限范围转到 RGB。HDR 参考用无损 HEVC 封装同一帧，验证解码后的 P010 与原始 P010 逐字节相同，再由 AVFoundation 的 `ForceSDR` 策略输出到 sRGB。

| 路径 | 基线 | 仅纠正 CVPixelBuffer 范围标签 | 修复后 | 独立参考 |
| --- | ---: | ---: | ---: | ---: |
| SDR → SDR，码值中位数 | 133.96 | — | 115.33 | 114.91 |
| HDR10 → SDR，码值中位数 | 150.36 | 123.89 | 124.59 | 129.80 |
| HDR10 → EDR，线性值中位数 | 0.48412 | 0.22900 | 0.23388 | — |

8 位码值按 `0.2126R + 0.7152G + 0.0722B` 统计，范围为 0–255。与独立参考相比，逐 RGB 通道的平均绝对误差在 SDR 上从 **18.50 降到 1.28**，在 HDR 转 SDR 上从 **23.33 降到 12.02**。EDR 数值来自 `RGBA16Float` 渲染纹理，描述送入 EDR 合成前的信号。

## 原因与修复

- 软件帧池固定按全范围创建。把同一个有限范围 SDR 帧装入池后，Core Video 像素格式从应有的 `420v` 变成 `420f`，HDR 从 `x420` 变成 `xf20`。只改缓冲区标签、不动原始样本和 shader，就能消除大部分偏亮。
- Metal 原先只用范围标签改变亮度偏移，仍给全范围样本乘有限范围的增益。8 位全范围灰阶输入 `[0, 16, 64, 128, 192, 235, 240, 255]` 修复前输出红通道为 `[1, 20, 75, 150, 224, 255, 255, 255]`，修复后逐级回到输入值。相同灰阶的有限范围编码修复后也得到同一组值。
- 缓冲池现在按帧的尺寸、像素格式和范围复用。Apple 软件转换显式传递 swscale 的输入和输出范围，避免旧式 `yuvj420p` 重排到 NV12 时默认被压到有限范围。Metal 矩阵按像素格式、亮度区间和色度区间归一化。
- 10 位全范围和有限范围的 1000 nit 灰阶，修复后分别读到 4.918 和 4.945，理论值为 `1000 / 203 ≈ 4.926`，差异与 10 位 PQ 量化相符。

HDR 转 SDR 在这一帧上仍与 AVFoundation 有可见差别，FSPlayer 的 Hable 曲线产生的码值中位数约低 5。这组实验通过离屏纹理验证了范围转换，以及缓冲池切换和软件像素转换。

## 取样命令

```sh
yt-dlp --no-playlist -f 243,332 -o 'youtube-%(format_id)s.%(ext)s' \
  'https://www.youtube.com/watch?v=9bw5-HNF5qI'
for id in 243 332; do
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=pix_fmt,color_range,color_space,color_transfer,color_primaries \
    -of json "youtube-${id}.webm"
done
ffmpeg -ss 34.2 -i youtube-243.webm -frames:v 1 -vf format=nv12 -f rawvideo sdr.nv12
ffmpeg -ss 34.2 -i youtube-332.webm -frames:v 1 -vf format=p010le -f rawvideo hdr.p010
```
