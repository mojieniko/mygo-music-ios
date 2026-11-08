# MyGo Music for iOS

MyGo Music for iOS 是基于 [egoist/mygo-music](https://github.com/egoist/mygo-music) 源码开发的非官方 iOS / iPadOS 移植与适配项目，使用 Swift、SwiftUI、JavaScriptCore 和 AVFoundation 构建，并尝试兼容原项目的 JavaScript 插件生态。

本项目由社区独立维护，与 MyGo Music 上游作者及项目没有隶属或官方合作关系。它仍在持续完善中，功能覆盖、设备适配和插件兼容性都可能不完整；如果遇到问题，欢迎包涵并通过 Issues 反馈。

## 下载

请从 [GitHub Releases](https://github.com/mojieniko/mygo-music-ios/releases) 下载最新的 `MyGoMusic.ipa`。安装包采用 ad hoc 签名，通常需要使用自己的 Apple 开发者签名或侧载工具重新签名后安装。

## 构建与运行

```sh
git clone https://github.com/mojieniko/mygo-music-ios.git
cd mygo-music-ios
open MyGoMusic.xcodeproj
```

在 Xcode 中选择 iPhone / iPad 模拟器或已配置签名的设备并运行。也可以在安装了完整 Xcode 的 macOS 上构建 IPA：

```sh
./build-ipa.sh
```

运行 Swift Package 测试：

```sh
swift test
```

## 项目结构

- `App/`：应用入口、Info.plist 与图标资源。
- `Sources/MyGoMusicCore/`：播放、歌词、本地媒体、插件运行时和状态管理。
- `Sources/MyGoMusicUI/`：SwiftUI 页面、播放界面和视觉效果。
- `Tests/`：核心逻辑测试。

## 来源与许可

本项目改编自 [MyGo Music](https://github.com/egoist/mygo-music)。上游版权与许可信息见 [上游仓库](https://github.com/egoist/mygo-music)；本项目按 GNU Affero General Public License v3.0（AGPL-3.0）发布，详见本仓库的 [`LICENSE`](LICENSE)。
