## 画中画（Picture in Picture）实现与踩坑记录

适用范围：iOS 15+ / macOS 12+。渲染走 `FSMetalView`（`AVSampleBufferDisplayLayer` 作为画中画内容源），
控制器封装在 `FSPlayer` 里，示例接入见 iOS `FSMoviePlayerViewController`、macOS `MRRootViewController`。

### 架构要点

- 画中画内容源用 `AVPictureInPictureControllerContentSource initWithSampleBufferDisplayLayer:playbackDelegate:`，
  不是 `AVPlayerLayer`。解码后的 `CVPixelBuffer` 在渲染线程（ff_vout）被 Metal 渲染的同时，复用同一份 buffer
  生成 `CMSampleBuffer` 喂给内容层（`FSMetalView -enqueuePictureInPictureSampleBuffer:`），只转换一次。
- 内容层挂在一个**普通容器视图**下，不能直接挂到 `CAMetalLayer` 上：AVKit 会给内容层建 host view 并按父层
  坐标算几何，`CAMetalLayer` 下会算出 NaN，AppKit 校验几何直接崩（`Invalid view geometry: x is NaN`）。
- `FSPlayer` 不是 `UIViewController`，界面层级（隐藏/恢复播放页）必须交给宿主，核心库只负责喂帧、状态同步、
  发通知/回调。

### 坑 1：进入画中画后画面停止更新

**现象**：进入画中画、隐藏（dismiss）播放页后，画中画窗口定格在最后一帧。

**根因**：示例的 `viewDidDisappear:` 在页面消失时 `shutdownSync:` 把整个播放器关了。画中画喂帧依赖解码持续
产出帧（ff_vout 线程无条件 enqueue），播放器一关，解码停止 → 不再有新帧。

**修复**：画中画激活期间，`viewDidDisappear:` 不要关闭播放器；用一个静态强引用兜住被 dismiss 的播放页，防止它
连同 `FSPlayer` 一起释放。`AVSampleBufferDisplayLayer` 内容源靠 enqueue 的 buffer 驱动，离屏也能继续显示，
只要播放器别停、承载 VC 别析构即可——不需要把渲染视图强留在窗口里。

### 坑 2：点击画中画“返回 App”崩溃

**根因**：核心库在 `restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:` 里对 `self`（一个
`FSPlayer`）调用了 `presentViewController:`，而它根本不是 `UIViewController`；加上 dismiss 后没人强引用该 VC，
可能已析构。

**修复**：`FSPlayer` 暴露 `pictureInPictureRestoreUIHandler` 回调，恢复界面交给宿主（宿主重新 present 播放页后
回调 `completionHandler`）；未设置回调时核心库直接 `completionHandler(YES)`，不做任何界面操作、也不崩。

### 坑 3：画中画窗口不显示时长 / 进度

**根因**：`AVSampleBufferDisplayLayer` 没有 `controlTimebase`，AVKit 无从推算“当前时间”，于是时长和进度条
都不显示（纯喂帧 + `DisplayImmediately` 是直播模式，本就没有进度）。

**修复**：`preparePictureInPicture` 时给内容层挂一个 `CMTimebase`（host clock 驱动），`FSPlayer` 通过
`-updatePictureInPictureTimebaseWithTime:rate:` 设锚点时间与速率；配合 delegate 的
`pictureInPictureControllerTimeRangeForPlayback:` 返回 `[0, duration]`，进度/时长就能显示。timebase 设好
rate 后自行随墙钟推进，无需逐帧更新。

> 已知小局限：timebase 按墙钟自走，网络缓冲期间进度可能短暂超前，seek/play/pause 会重新锚定校正。若要更准，
> 可在 `FFP_MSG_BUFFERING_END` 再同步一次。

### 坑 4：播放状态（播放/暂停按钮、播放结束）不同步到画中画

**根因**：AVKit 会缓存 `AVPictureInPictureSampleBufferPlaybackDelegate` 的返回值，必须调用
`invalidatePlaybackState` 才会重新查询暂停状态与时间轴。

**修复**：`FSPlayer` 新增 `syncPictureInPicturePlaybackState`（更新 timebase + `invalidatePlaybackState`，
主线程执行），在 play / pause / seek 完成 / 播放状态变化（含结束、出错）/ 控制器准备 / 启动 PiP 各处调用。
注意 `postEvent:` 本身在主线程（`performSelectorOnMainThread`），消息回调里可直接调。

### 坑 5：发起新播放时旧画中画不结束，叠出两个播放器

**根因 A**：AVKit **程序化** `stopPictureInPicture` 时，若源界面已隐藏，**仍会回调**
`restoreUserInterfaceForPictureInPictureStop`。若不拦截，旧播放页会被 restore 回调重新 present 回来，和正在
present 的新播放页叠成两层（需关两次）。
→ 修复：为“为新播放丢弃旧页”这个场景加 `pipDiscarding` 标志，restore 回调检测到它就直接 `completionHandler(NO)`
且不 present；旧播放器照常在 `didStopPictureInPicture` 分支里关闭并释放。

**根因 B**：结束旧画中画的逻辑一开始只放在 `presentFromViewController:` 一个入口，而在线示例视频走的是
`FSDemoSampleViewController` 里直接 `alloc/initWithURL:` + `presentViewController:`，`initWithTemporaryMovieURL:`
等入口同理，**绕过了**该逻辑 → 在线视频场景旧 PiP 不停止。
→ 修复：把“结束上一条残留 PiP”的逻辑挪到每个播放页都必经的 `viewDidLoad`，用 `holding != self` 守卫，覆盖所有
创建路径。

### 退出画中画的三条路径（示例的处理约定）

| 触发 | AVKit 是否回调 restore | 期望结果 |
| --- | --- | --- |
| 用户点“返回 App” | 是（`pipRestoring`=YES） | 重新 present 播放页，继续播放 |
| 用户点画中画关闭(X) | 否，仅 `didStop` | 关闭播放器，留在列表页 |
| App 内发起新播放 | 是（`pipDiscarding`=YES，被拦截） | 旧页关闭，只剩新播放页 |

### 内存安全提醒

- 状态回调里若会把唯一强引用（静态持有）置空，先在方法入口用一个局部 `__strong` 变量兜住 `self`，否则置空的
  那一刻 `self` 可能立即析构，方法后续代码在已释放对象上运行。
- 清空静态强引用时加 `== self` 守卫：新旧播放页竞态下，静态引用可能已指向新页，别误清。

### 工程配置

- 若要 App 退到后台时画中画继续播放，需在宿主 App 的 Info.plist 开启 Background Modes 的
  “Audio, AirPlay, and Picture in Picture”，并保持 playback 类别的音频会话激活；否则后台会被系统挂起。

### 坑 6：macOS 画中画只按原生尺寸显示、只露出左上一块（放大窗口才看到更多）

**现象**：macOS 进入画中画后，视频不按窗口缩放，而是按**原始像素 1:1** 显示，小窗只露出左上角一块，
放大画中画窗口能看到更多内容。iOS 正常。

**根因（AVKit 框架缺陷，非本项目代码问题）**：macOS 上，`AVPictureInPictureControllerContentSource`
以 `sampleBufferDisplayLayer:` 方式提供内容时，AVKit 把我们的 `AVSampleBufferDisplayLayer` 搬进它自建的
PiP 面板，用一个私有视图 `AVPictureInPictureCALayerHostView` 承载，但**只在面板初次出现时按视频原生尺寸
布局一次**、之后不跟随窗口，且**不按 `videoGravity` 缩放**。参见
[Apple 论坛](https://developer.apple.com/forums/thread/821582)、
[社区修复 PR（MenuBarMijia #268）](https://github.com/jryang1997/MenuBarMijia/pull/268)。

> 弯路记录：最初两次把它误判为 VideoToolbox 对齐 padding + Clean Aperture 裁剪问题，改了 offset、
> 传了显示尺寸——都无效。因为标准 1080p 只有竖直约 8px padding，不可能造成约 17% 的横向偏移，方向从一开始
> 就错了。真正的线索是“画面完整但整体缩在左上、放大窗口看到更多”＝没有缩放，而不是裁切。

**修复（`FSMetalView`，仅 macOS）**：反向进入 AVKit 的 PiP 面板视图层级做布局修正。实测层级（macOS，PiP 面板
类名 `PIPPanel`）：

```
PIPPanel.contentView(NSView，跟随窗口)
  AVPictureInPictureSampleBufferDisplayLayerView      ← 卡在初始尺寸(如1259×708)、不跟随窗口 → 被窗口裁掉
    AVPictureInPictureSampleBufferDisplayLayerHostView(layer=CALayerHost) ← 同样卡住，承载镜像内容
      AVPictureInPictureCALayerHostView               ← 停在窗口上方的黑色占位视图(origin.y>0)
```

承载视频的两层类名都含 **`DisplayLayer`**，黑色占位是 `CALayerHostView`（不含 `DisplayLayer`），以此精确区分：
- 递归把所有含 `DisplayLayer` 的视图 `autoresizingMask` 设为 `width|height`、frame 贴合其 superview.bounds
  （父先子后，子读到的已是修正尺寸），并同步其 `CALayerHost` 层 bounds；
- 黑色占位视图（含 `CALayerHostView` 且不含 `DisplayLayer`、`origin.y>0`）单独移出可视区；
- 时机：`setPictureInPictureActive:YES` 时启动（PiP 窗口 `PIPPanel` 异步出现、AVKit 分多个 runloop 布局，故
  立即 + 延迟 0.05/0.15/0.35/0.7s 多次重试），并监听 `NSWindowDidResizeNotification`（仅类名含 "pip" 的窗口）
  持续修正；退出时注销观察者。
- 匹配私有类名失败时安全退出（退回 AVKit 原生 1:1 行为，不崩）。

> 弯路记录：
> 1. 先误判为 VideoToolbox padding + Clean Aperture 裁剪，改 offset、传显示尺寸——无效（1080p 只有几像素
>    padding，不可能造成约 17% 偏移）。真正线索是“画面完整但缩在左上、放大窗口看到更多”＝没缩放，不是裁切。
> 2. 再按社区 PR 盲套类名 `AVPictureInPictureCALayerHostView` + `"host"/"CALayer"`——仍无效，因为那层是
>    黑色占位，真正要填充的是 `AVPictureInPictureSampleBufferDisplayLayerView`（既不含 host 也不含 CALayer）。
>    最终靠运行时 dump（`dumpPictureInPictureHierarchy`，代码保留备用）拿到真实层级才定位到 `DisplayLayer` 这个键。

> ⚠️ 依赖 AVKit **私有视图类名**（`...SampleBufferDisplayLayerView`、`PIPPanel` 等），属脆弱绕法，系统升级
> 可能失效；失效时仅退回“显示不完整”，不崩。需在 macOS 真机验证，后续系统回归。若失效，重新启用
> `dumpPictureInPictureHierarchy` dump 新层级，按新类名调整 `DisplayLayer` 匹配键。
