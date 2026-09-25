# simple-unzip-mac

macOS 平台上的图形化解压缩工具。界面使用 SwiftUI 编写；压缩与解压由 7-Zip 官方源码
编译出的命令行程序 `7zz` 完成。

*A GUI wrapper around the 7-Zip command line tool for macOS.*

---

## 下载

到 [Releases](https://github.com/see-gull/simple-unzip-mac/releases) 页面下载最新的
`Simple Unzip.zip`，解压后把 `Simple Unzip.app` 拖进「应用程序」文件夹即可。

> **首次打开被系统拦住？** 本应用未做代码签名与公证，macOS 会提示「无法验证开发者」。
> 在「应用程序」里右键点击 → 选择「打开」→ 在弹窗里再点一次「打开」，之后即可正常双击启动。

---

## 面向谁

**适合：**

- 在 macOS 上偶尔需要处理 `.7z`、`.rar`、`.tar.gz` 等格式，不希望为此购买收费软件的
  个人用户；
- 不熟悉命令行，希望用拖拽或双击完成操作的用户；
- 希望使用 7-Zip 官方引擎，而不是来源不明的第三方二进制的人。

**不适合：**

- 需要命令行集成、批量自动化脚本的场景；
- 需要商业级稳定性、技术支持或长期维护承诺的场景；
- 需要 Finder 右键菜单集成的场景（本项目未实现）。

## 关于作者与免责

这是一个个人练习性质的封装项目。作者不是专业的 macOS 应用开发者，在界面设计、
异常处理和工程规范上都存在能力不足之处。

它能够完成压缩与解压的基本操作，但距离商业软件的完成度还有明显差距：未做代码签名与
公证，未做多机型适配测试，部分冷门格式没有充分验证。具体见「已知限制」一节。

如果发现错误、或者有更好的实现方式，欢迎提 Issue 指正。不到之处，敬请包涵。

## 与 7-Zip 的关系

需要明确说明：**本项目不是 7-Zip 的官方项目，也不是对压缩算法的重新实现。**

### 无关联声明

本项目由个人独立开发，与下列主体**没有任何关联**，也未获得其任何形式的授权、
赞助或背书：

- **Igor Pavlov**（7-Zip 的作者及该名称的权利人）
- **Alexander Roshal / RARLAB**（RAR、WinRAR 的作者及该名称的权利人）

本项目的产品名称中**不包含** "7-Zip"、"RAR"、"WinRAR" 等第三方商标。文中出现这些
名称，仅为**说明本软件使用了哪一款引擎、支持哪些格式**这一事实，属于描述性使用。

### 本项目的技术分工

7-Zip 官方源码的 macOS 版本只提供命令行程序 `7zz`，没有图形界面。本项目做的是三件事：

1. 从 **7-Zip 官方源码**（版本 **26.03**）编译出 `7zz`；
2. 为其编写一个 SwiftUI 图形界面；
3. 把编译产物 `7zz` 一并打包进 `.app` 应用包。

因此：

- **压缩与解压的正确性由 7-Zip 保证**，本项目不对此负责；
- 本项目负责的是界面交互、任务调度、进度解析与应用打包；
- 使用的 7-Zip 源码从官方渠道下载，并做了**双渠道哈希比对**验证：

  | 渠道 | SHA-256 |
  | --- | --- |
  | `https://www.7-zip.org/a/7z2603-src.tar.xz` | `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4` |
  | `https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz` | `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4` |

  两个官方渠道的文件完全一致。源码按 LGPL 授权使用，详见「许可证」一节。

## 功能

| 功能 | 说明 | 状态 |
| --- | --- | --- |
| 压缩 | 7z / ZIP / TAR / TAR.GZ / TAR.BZ2 / TAR.XZ / GZIP / BZIP2 / XZ / WIM | 已验证 |
| 解压 | 解压全部或选中条目；可选平铺目录、四种同名文件处理策略 | 已验证 |
| 内容浏览 | 树形列出包内文件，显示大小与修改时间，支持筛选 | 已验证 |
| 加密 | 7z 与 ZIP 支持密码；7z 可同时加密文件名 | 已验证 |
| 任务队列 | 多任务排队、实时进度、可取消、可查看 7-Zip 原始输出 | 已验证 |
| 完整性校验 | 对压缩包执行 `7zz t` | 已验证 |
| `.tar.*` 穿透 | 浏览 `.tar.gz` / `.tar.xz` 时显示内层真实文件 | 已验证 |
| macOS 适配 | 默认排除 `.DS_Store` / `__MACOSX`；中文与空格路径正常 | 已验证 |

界面截图见 [`docs/previews/`](docs/previews/)。

## 项目结构

```
.
├── app/                        Swift Package
│   ├── Package.swift
│   └── Sources/
│       ├── ArchiveKit/        引擎层：无 UI 依赖，可独立复用
│       ├── SimpleUnzip/        SwiftUI 界面层
│       ├── SelfTest/           自检程序
│       └── ExhaustiveTest/     格式 × 级别 × 密码的穷举测试
├── scripts/
│   ├── fetch-source.sh         下载并校验官方 7-Zip 源码
│   ├── build-app.sh            编译引擎 → 编译界面 → 组装 .app
│   ├── make-icon.swift         生成应用图标
│   └── diagnostics/            排查用的窗口枚举工具
├── licenses/                   第三方组件的许可文本
│   ├── 7-Zip-License.txt       7-Zip 源码的分发与使用许可
│   ├── LGPL-2.1.txt            GNU LGPL 2.1 全文
│   └── unRarLicense.txt        unRAR 代码许可
├── docs/
│   ├── verification.md         验证记录：证据、弯路与未验证项
│   ├── selftest-output.txt     自检完整输出
│   └── previews/               界面截图
└── README.md
```

分层结构如下，界面层不直接接触命令行参数：

```
SimpleUnzip (SwiftUI)
    │  仅调用 ArchiveKit 的 async API
    ▼
ArchiveKit
    ├── ArchiveTool          定位 7zz、读取版本
    ├── RunningProcess        子进程启动、流式读取、取消
    ├── ArchiveOutputParser  解析进度与日志
    ├── ArchiveListing        解析 `l -slt` 输出，构建目录树
    └── ArchiveEngine        list / compress / extract / test
    ▼
7zz（从官方源码编译，随应用打包）
```

## 构建与运行

环境要求：macOS 13 或更高版本，已安装 Xcode Command Line Tools。

```bash
git clone https://github.com/see-gull/simple-unzip-mac.git
cd simple-unzip-mac

./scripts/fetch-source.sh      # 下载官方源码（含哈希校验）
./scripts/build-app.sh         # 构建，产出 dist/Simple Unzip.app

open "dist/Simple Unzip.app"
```

引擎已编译过时，第二步可加 `--skip-engine` 跳过重新编译。

构建脚本会自动处理本机环境的两个限制：SwiftPM 需要 `--disable-sandbox`
（它内部会调用 `sandbox-exec`），以及把编译缓存重定向到工作区内。

如需分发现成二进制，建议将 `dist/Simple Unzip.app` 压缩后发布到 GitHub Releases，
而不是提交进仓库。**但请注意：一旦分发二进制，就触发 LGPL「提供对应源码」的义务**，
详见「许可证」一节的说明。

## 测试

项目自带检查程序，**不依赖 XCTest**（Command Line Tools 中不包含该框架）：

```bash
cd app
ARCHIVE_TEST_BINARY="../build/bin/7zz" \
ARCHIVE_TEST_TMP="../build/testtmp" \
ARCHIVE_STAGING_DIR="../build/staging" \
swift run --disable-sandbox --scratch-path ../build/app-build SelfTest
```

当前结果：**通过 51 ｜ 失败 0**。覆盖范围包括输出解析、进度解析、真实压缩包往返、
三种压缩型 tar、加密与错误密码处理、任务取消、中文与空格路径。

也可对指定的真实文件执行一次完整的列表与解压往返：

```bash
ARCHIVE_EXTRA_ARCHIVE="/绝对路径/某文件.tar.xz" swift run … SelfTest
```

详细的验证证据、开发过程中走过的弯路，以及**明确未能验证的部分**，记录在
[`docs/verification.md`](docs/verification.md) 中。建议先阅读其中的第 6 节。

## 已知限制

以下限制是已知的，不是意外行为：

- **未做代码签名与公证**。本机可以运行；复制到其他机器会被 Gatekeeper 拦截，
  需要右键打开或自行签名。
- **未实现 Finder 右键扩展**，只能从应用内操作或拖拽文件。
- **浏览或解压 `.tar.*` 需要一份临时中间文件**。7-Zip 命令行不会穿透压缩层，
  因此需要先剥出完整 tar。其体积约等于解压后的内容——实测 7.6 MB 的 `.tar.xz`
  会临时写出 121 MB（约 0.8 秒），完成后立即删除。超大归档的打开会明显变慢。
- **`.gz` / `.bz2` / `.xz` 只能压缩单个文件**。这是格式本身的限制（它们不是归档格式，
  没有目录结构概念），不是程序的缺陷。压缩文件夹请选用 TAR.GZ / TAR.XZ。
- **冷门格式未做穷举测试**。ISO/WIM、特殊分卷等只验证了通用路径，没有逐个构造样本测试。
- **不支持创建 RAR 压缩包**。RAR 压缩算法属于未公开的专有技术，第三方不存在合法实现；
  本软件对 RAR 只具备**解压**能力（由 7-Zip 引擎提供）。
- **未做多机型与深色模式适配测试**。界面截图基于单一显示环境生成。
- **界面自动化验证受限**。本机缺少屏幕录制权限，界面验证改用离屏渲染加人工操作，
  未能覆盖拖放、快捷键等全部交互路径。

## 免责声明与数据安全

**请在使用前阅读。**

本软件按 **"AS IS"（现状）** 提供，不附带任何形式的明示或暗示担保，包括但不限于对
适销性、特定用途适用性和不侵权的担保。在法律允许的最大范围内，作者不对因使用或无法
使用本软件而产生的任何损失承担责任，包括数据丢失、文件损坏、利润损失等。

**关于数据安全，特别提醒：**

- 解压遇到同名文件时会按你选择的策略处理，**默认策略是覆盖**。请在解压到已有内容的
  目录前确认，或改用「跳过已存在」/「重命名」。
- 压缩操作可能覆盖同名的已有压缩包。
- 不建议把本软件作为唯一的数据保管手段。**重要数据请始终保留独立备份。**
- 本软件尚未经过广泛测试，作者能力有限（见「关于作者与免责」一节），
  请勿用于对可靠性有严格要求的场景。

## 许可证

本项目分为两部分，适用不同许可：

- **界面与引擎封装代码**（`app/Sources/SimpleUnzip`、`app/Sources/ArchiveKit`、
  `scripts/`）：**MIT License**，见 [`LICENSE`](LICENSE)。

- **7-Zip 引擎**：来自 Igor Pavlov 的官方源码，适用 **GNU LGPL**（其中部分文件另用
  BSD-2/BSD-3 或 public domain，以 7-Zip 的 `License.txt` 为准）。许可文本已随仓库
  提交到 [`licenses/`](licenses/)，也会随应用打包进 `Contents/Resources/`。

### 关于 RAR 代码的强制声明

7-Zip 引擎中包含源自 unRAR 的代码，其许可要求分发时必须作出如下明确声明：

> The unRAR sources may be used in any software to handle RAR archives without
> limitations free of charge, but **cannot be used to re-create the RAR
> compression algorithm, which is proprietary**. Distribution of modified
> unRAR sources in separate form or as a part of other software is permitted,
> provided that it is clearly stated in the documentation and source comments
> that **the code may not be used to develop a RAR (WinRAR) compatible
> archiver**.

据此声明：

1. **本项目中包含的 unRAR 相关代码，不得被用于开发任何 RAR（WinRAR）兼容的压缩程序。**
2. 本项目自身即遵守此限制：**不提供、也不会提供 RAR 压缩功能**，仅使用 unRAR 代码
   读取与解压 RAR 归档——这是该许可明确允许的用途。
3. 本软件免费提供，不对 unRAR 相关部分收取任何费用。

### 关于分发二进制

LGPL 允许分发二进制，但要求同时提供对应的源代码。**如果你打算发布打包好的
`.app`（例如 GitHub Releases）**，请一并满足以下任一条件：

- 附带 7-Zip 对应版本的完整源码包；或
- 在文档中写明源码获取方式（版本号 + 官方地址 + 哈希），并提供有效的书面获取承诺。

仓库内的 `scripts/fetch-source.sh` 已包含下载地址与哈希校验，可作为参考。
若不确定如何合规，**最稳妥的做法是只发布源码，让使用者自行构建**——这样不产生
二进制分发行为。
