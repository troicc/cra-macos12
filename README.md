<p align="center">
  <img src="brand/cra-segments-icon.svg" alt="Cra logo" width="128" height="128">
</p>

<h1 align="center">Cra for macOS 12</h1>

<p align="center">
  把 <a href="https://github.com/VictorKildahl/cra">Cra</a>（一个仿 Arc 的开源浏览器）移植到 macOS 12.6 Monterey，<br>
  并加上一组本地化、不经第三方的网络隐私功能：每个 profile 独立代理、WebRTC 防泄漏、出口 IP 显示、时区匹配。
</p>

<p align="center">
  <img alt="macOS 12.6+, Apple silicon" src="https://img.shields.io/badge/macOS-12.6%2B%20·%20Apple%20silicon-lightgrey">
  <img alt="Chromium 150" src="https://img.shields.io/badge/engine-CEF%20150%20(Chromium%20150)-blue">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

上游 Cra 只支持 macOS 14 及以上。这个分支（`macos12`）让它在 macOS 12.6 的 Apple silicon Mac 上运行，
侧边栏、Space、固定标签、收藏、命令栏、分屏、Little Window、Arc 导入等功能照旧可用。
在此之上新增的网络隐私功能全部在本机完成，配置和密码不离开这台 Mac。

## 安装

本分支没有签名的 DMG，也没有自动更新。每次推送到 `macos12`，GitHub Actions 的
[`build-macos12.yml`](.github/workflows/build-macos12.yml) 会构建一次（约 10 分钟）：

1. 打开仓库的 **Actions → Build Cra for macOS 12.6 (CEF 150)**，进入最新一次成功的运行，
   下载 `Cra-macOS12-arm64` 压缩包；或者用命令行：
   `gh run download <run id> -n Cra-macOS12-arm64`
2. 解压得到 `Cra.app`，放到任意位置。
3. 构建只做了 ad-hoc 签名，第一次打开要在 Finder 里右键 → 打开，或执行
   `xattr -dr com.apple.quarantine Cra.app`。

只构建 Apple silicon（arm64）版本。

## 针对 macOS 12 做了什么

### 引擎：CEF 150

Chromium 151 起最低要求 macOS 13，所以 150 是能在 macOS 12 上运行的最后一个版本。本分支用的是
[OBS Studio 33](https://github.com/obsproject/obs-studio) 发布的 CEF 150.0.19 二进制（最低系统 12.0），
它编进了专有解码器：**H.264、AAC、HEVC 视频可以播放**。普通的 CEF 150 构建没有这些解码器，
X、Instagram、Reddit 上的 MP4 都放不了。

上游 Cra 在 Chromium 上打了约 30 个补丁（`scripts/cef-patches`）。自己编译带补丁的 CEF 150 需要约 80 GB 空间和新版
Xcode，GitHub 的构建机放不下，所以本分支用的是**未打补丁**的 CEF，和上游有这些差别：

- 重启后，标签页本身会恢复，但每个标签页的前进 / 后退历史不会恢复（上游靠补丁里的 `Cra.getHistory`）。
- 设置 → Privacy 里的 **Fingerprinting protection** 开关在这个版本上不起作用：它依赖补丁，canvas、WebGL、
  音频指纹都是真实值。
- 一部分扩展、翻译和预加载页面的细节行为与上游不同。

### 代码适配

都是"在 macOS 12 上能编译、运行起来却不对"的问题，逐个修正：

- **系统 API 可用性**：把 macOS 13+ 才有的 API 换成 12 上可用的写法，包括 `Duration` 改为 `TimeInterval`，
  以及 `Locale`、`URL` 的相关接口（CraCore 和 App 两层）。
- **URL 解析**：macOS 14 的 `URL(string:)` 比 12 宽松，很多代码依赖这一点。
  `LenientURLParsing` 让 macOS 12/13 按 14 的规则解析。
- **SwiftUI 状态更新**：macOS 12/13 没有 Observation 框架，所有 SwiftUI 视图都改为通过 Perception 跟踪状态，
  否则界面不会随数据刷新。
- **窗口和绘制**：
  - 设置窗口固定为 684 × 650，避免被内容撑大；
  - 红绿灯按钮位置限制在合理范围；
  - 修正零尺寸视图触发的 `setFrameOrigin` 断言；
  - SwiftUI 渲染出的图片按 Retina 倍率绘制；
  - 卡片阴影不再被裁成方角；
  - 应用图标按 Apple 的网格重画。
- **CEF 150 差异**：去掉 CEF 156 才有的权限类型，修正页面弹窗和嵌入页面绘制的检测。
- **Library ▸ Media 已关闭**：入口改为打开 Downloads。
- **构建**：拆分 `Package.swift` 里的大数组，避免 Swift 类型检查超时；CraCore 测试跟着改过的类型同步更新。

### macOS 12 上用不了的功能

- **Arc Max 的本机 AI 功能**（Ask on Page、Tidy Tabs 等）：它们依赖 Apple Intelligence，需要 macOS 15.1 及以上。

## 新增功能：网络隐私

目标是一个**固定、一致、不泄漏真实 IP** 的上网环境，而不必把账号和 cookie 交给第三方指纹浏览器。
新功能都不是 Arc 原有的，默认关闭或保持原样，需要手动开启。

### 每个 profile 独立代理

**设置 → Profiles →（选中一个 profile）→ Network → Proxy**

- 三种选择：**macOS Settings**（跟随系统代理，默认）、**No Proxy**、**Proxy Server…**（指定服务器）。
- 支持 HTTP、HTTPS、SOCKS4、SOCKS5，并识别代理商常给的几种写法：
  `socks5://host:port`、`http://user:pass@host:port`、`user:pass@host:port`、`host:port`、`host:port:user:pass`。
- 设置写入这个 profile 自己的 Chromium 偏好，下次启动时在第一个页面加载前就已生效。
- **代理断了就断网**：页面直接失败（`ERR_PROXY_CONNECTION_FAILED`），不会退回直连而暴露真实 IP。
  只有本机回环地址不经过代理，这是 Chromium 的固定行为。
- **代理密码存在 macOS 钥匙串**（服务名 `Cra Proxy`），不写进任何配置文件或日志。
  Cra 会先用自己的一次请求登录代理；因为 Chromium 的代理登录缓存是整个 profile 共用的，之后网页直接通过，
  不会弹 Chrome 的登录框。
- 同一个 profile 下的所有 Space 共用一个代理和一个环境。要不同身份，就把 Space 放到不同的 profile 上。

### WebRTC 防泄漏

修掉了上游的一个泄漏：原来的 WebRTC 策略只隐藏内网地址，但 STUN 请求走 UDP、绕过 HTTP/SOCKS 代理，
网页能从 STUN 的回应里读到真实公网 IP。

- 现在每个 profile 按**自己实际生效的代理**判断：在代理后面（包括 Clash、Surge 一类工具设置的 macOS 系统代理），
  WebRTC 只走代理（`disable_non_proxied_udp`）；没有代理时保持原来的行为。
- 代理一变就重新判断，在页面能用到之前完成。
- **设置 → Privacy → Exit IP → Keep WebRTC behind the proxy**：无论有没有检测到代理都强制只走代理，
  适合代理设在路由器上、Cra 看不到的情况。代价是需要 UDP 的视频通话可能连不上。

### 出口 IP 显示

**设置 → Privacy → Exit IP → Show the exit IP in the menu bar**

- 菜单栏显示当前 Space 所属 profile 的出口：国旗 + IP。点开可以看到位置、网络（ASN）、时区、当前代理、
  WebRTC 状态，并能复制 IP、立即重新检测。
- 查询**通过这个 profile 自己的代理**发出，看到的就是网站看到的地址。每分钟查一次，代理或网络一变立即再查。
  连续两次查不到，图标变红。
- 查询服务可选 ipinfo.io（默认）、ipapi.co、ipwho.is、ifconfig.co、ipify。查询服务只能看到出口 IP，
  这个地址每个网站本来就看得到。
- 日志里只记录"出口变了 / 查询失败"，不写 IP 本身。

### 时区匹配

**设置 → Privacy → Exit IP → Match the time zone to the exit IP**

- 网页看到的时区（`Date`、`Intl`，以及同一进程里的 Worker）换成出口 IP 所在地的时区，
  避免"美国 IP、上海时区"这种一眼就能看出的矛盾。
- 每个 profile 用自己出口的时区；已打开的页面立即生效。
- 记住每个 profile 上一次的出口，启动时恢复的标签页一开始就是对的时区。

### 已知限制

- **带密码的 SOCKS5 代理用不了**：Chromium 不支持 SOCKS 认证。多数代理商同时提供同地址、同账号的 HTTP 入口，那个可以用。
- **HTTP 代理协议本身是明文**：发给代理的请求会带上目标域名和账号（网页的 HTTPS 内容仍是加密的）。
  代理商提供 `https://` 入口时，优先用它。
- **Chromium 的后台请求**（组件更新、安全浏览名单等）走全局的系统网络通道，跟随 macOS 系统代理，
  不走 profile 设的代理；Cra 自己的更新检查和拦截列表下载也一样。这些请求网站看不到。
- **无痕窗口不做时区匹配**；它会不会沿用 Default profile 的代理还没有验证。
- 启动时恢复的标签页如果比 Cra 的代理登录请求先发出，可能会看到一次 Chrome 的代理登录框。
- 没有做硬件指纹（canvas、WebGL、字体）伪装。在一台真实的 Mac 上保持真实、固定的指纹，比伪装更不容易露馅；
  而且未打补丁的 CEF 也做不到原生级伪装。

## 从源码构建

本地需要较新的 Xcode / Swift 工具链（Package 使用 swift-tools 5.10）。macOS 12 上的 Xcode 13 编不了这个项目，
所以本分支的构建都在 GitHub Actions 上完成：推送到 `macos12` 分支即可触发，产物和测试结果都在 Actions 页面。

在较新的 Mac 上也可以本地构建：

    CRA_ENGINE=cef CRA_ALLOW_STOCK_CEF=1 scripts/build.sh release

（CEF 的下载地址和校验值见 workflow 文件。）

## 测试

- **CraCore 单元测试**：CI 在构建之后运行，包括新增的 `ProxySettingTests`（代理解析、WebRTC 策略判断）和
  `ExitIPTests`（各查询服务的返回解析、离线判断、时区选择）。
- **场景测试**：用已构建的 App 在本机跑，不需要屏幕录制权限：

      CRA_APP=/path/to/Cra.app scripts/scenario.sh proxy-exit-ip

  `proxy-exit-ip` 把测试用的本地服务器当成 HTTP 代理，从头到尾验证一遍：WebRTC 策略切换、页面经过代理、
  通过代理查出口 IP、时区覆盖、代理密码登录，以及代理断开时页面失败而不是直连。

## 致谢与许可

基于 Victor Kildahl 的 [Cra](https://github.com/VictorKildahl/cra)，按 [MIT 许可](LICENSE)使用和修改。
本分支与上游作者无关，问题请在本仓库提出，不要报到上游。
