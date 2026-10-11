# NGA HarmonyOS

NGA 论坛 HarmonyOS 原生客户端，使用 ArkTS、ArkUI 和 Stage 模型开发。

当前工程版本：3.7.6。源码整理日期：2026-10-10。

## 功能

- 收藏、板块浏览、消息和个人设置。
- 话题列表、详情、翻页、刷新、收藏与缓存。
- 帖子和回复中的图片、表情显示，图片预览与保存。
- 发帖、回帖、短消息回复以及图片和表情插入。
- 日间与夜间主题、系统栏沉浸适配和支持设备上的沉浸光感、智感握持。

## 开发环境

- DevEco Studio：需要支持工程所用 SDK 的版本。
- 编译 SDK 和目标 SDK：26.0.0；兼容 API：21。工程使用 `runtimeOS: OpenHarmony`，需安装对应的 OpenHarmony SDK。
- Node.js、JDK 和 Hvigor：使用 DevEco Studio 配套工具。
- 运行前需要配置本机 SDK 和应用签名。

## 导入、构建与运行

1. 在 DevEco Studio 中打开本目录，即包含 `build-profile.json5` 的目录。
2. 安装 OpenHarmony SDK 26.0.0，配置本机 SDK 目录，并等待 IDE 完成依赖同步。依赖由 `oh-package.json5` 和 `oh-package-lock.json5` 管理。
3. 编译工程；在 IDE 中按自己的开发账号和设备配置签名后，再运行到模拟器。
4. 默认使用模拟器调试，真机测试需连接并配置自己的设备。

本源码不包含签名证书、私钥、密码或已有设备的授权描述文件。导出的 `build-profile.json5` 保留空的 `signingConfigs`，已移除引用本地 `default` 签名的字段，支持先构建未签名 HAP。签名后才能安装运行。

Windows 下也可使用 DevEco 自带的 Hvigor 命令行构建未签名 HAP：

```powershell
# 将此路径改为自己的 DevEco Studio 安装目录。
$env:DEVECO_STUDIO_PATH = "C:\Program Files\Huawei\DevEco Studio"
$env:DEVECO_SDK_HOME = Join-Path $env:DEVECO_STUDIO_PATH "sdk"
# 指向包含 26.0.0 子目录的 OpenHarmony SDK 根目录，按本机位置修改。
$env:OHOS_BASE_SDK_HOME = "C:\HarmonySdk"
$env:JAVA_HOME = Join-Path $env:DEVECO_STUDIO_PATH "jbr"
$env:PATH = (Join-Path $env:JAVA_HOME "bin") + ";" + $env:PATH
& (Join-Path $env:DEVECO_STUDIO_PATH "tools\node\node.exe") `
  (Join-Path $env:DEVECO_STUDIO_PATH "tools\hvigor\bin\hvigorw.js") `
  assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon
```

IDE 可以通过本机生成的 `local.properties` 中的 `sdk.dir` 指定 SDK；命令行可以使用 `OHOS_BASE_SDK_HOME`。两者都应指向包含 `26.0.0/` 的 SDK 根目录，而不是单个 `ets/` 目录。本机路径文件已列入忽略规则。

编译产物位于 `entry/build/default/outputs/default/`。安装包适合通过 GitHub Releases 分发，源码仓库不包含它们。

## 回归测试

`tools/` 包含现有 Node.js 回归测试和公开、匿名化的测试样本。测试直接加载工程源码，部分需要 DevEco SDK 配套的 TypeScript 编译器。默认跳过可选的联网测试。

在工程根目录运行：

```powershell
$env:DEVECO_HOME = "C:\Program Files\Huawei\DevEco Studio"
$env:TYPESCRIPT_PATH = Join-Path $env:DEVECO_HOME `
  "sdk\default\openharmony\ets\build-tools\ets-loader\node_modules\typescript"
$env:ETS_TYPESCRIPT_PATH = $env:TYPESCRIPT_PATH
$testFiles = @(Get-ChildItem -LiteralPath "tools" -Filter "test-*.cjs" |
  Sort-Object Name | ForEach-Object { $_.FullName })
& (Join-Path $env:DEVECO_HOME "tools\node\node.exe") --test $testFiles
```

如果 SDK 的编译器布局不同，将 `TYPESCRIPT_PATH` 和 `ETS_TYPESCRIPT_PATH` 改为实际的 TypeScript 模块目录。`tools/` 中的 Python 文件用于可选的界面诊断，需要 Python 3 和 Pillow（`python -m pip install Pillow`）；见各脚本说明。

## 目录

```text
AppScope/             应用级配置和图标
entry/src/main/       页面、组件、数据模型和资源
entry/                模块构建和混淆配置
hvigor/               Hvigor 配置
tools/                回归测试和测试样本
LICENSE               工程已有 GPL v2 许可证
AGENTS.md             本工程的 Agent 开发约定
```

## 账号与本地数据

账号由用户在应用中登录。个人登录状态、Cookie、消息和应用缓存属于运行时数据，不包含在此源码导出中。不要提交个人签名配置、私钥、密码或调试过程中保存的账号数据。

## 许可证

沿用原工程的 GNU GPL v2 许可证，详见 `LICENSE`。保留源码中的原有版权声明；第三方组件许可见 `entry/src/main/resources/rawfile/OSLICENSE.TXT`。
