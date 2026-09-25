# 验证记录

本文记录每一项结论背后的**实测证据**，以及**未能验证的部分**。所有命令都在本工作区内
真实执行过，输出已归档在 `docs/`。

---

## 1. 源码来源与完整性

从 7-Zip 官方下载页公布的两个渠道各取一份源码包：

| 渠道 | 文件 | SHA-256 |
| --- | --- | --- |
| `https://www.7-zip.org/a/7z2603-src.tar.xz` | `source/7z2603-src.tar.xz` | `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4` |
| `https://github.com/ip7z/7zip/releases/download/26.03/7z2603-src.tar.xz` | `source/gh-7z2603-src.tar.xz` | `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4` |

**两份哈希完全一致**，且 `xz -t` 通过、字节数与服务器 `Content-Length`（1552200）一致。
7-zip.org 未提供 `.sha256` 文件（请求返回 404），因此采用双渠道比对作为替代验证。

版本：**7-Zip 26.03 (2026-09-03)**。

## 2. 引擎从源码构建

```
cd source/src/CPP/7zip/Bundles/Alone2
make -j8 -f ../../cmpl_mac_arm64.mak
```

产物：`b/m_arm64/7zz`，已复制到 `build/bin/7zz`。实测：

```
$ file build/bin/7zz
7zz: Mach-O 64-bit executable arm64

$ ./build/bin/7zz | sed -n 2p
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
```

与 Homebrew 版本号一致，但**这是本工作区自己编译的产物**，后续所有测试均针对它运行。

## 3. 引擎行为实测（写代码前先摸清楚）

这些是设计解析器时依赖的原始观测，不是推测：

**`7zz l -slt` 的格式**：`--` 之后是归档级属性，`----------` 之后是若干以空行分隔的
`Key = Value` 记录；目录条目的 `Attributes` 以 `D` 开头；固实块中每文件的
`Packed Size` 会**省略**；时间戳带 7 位小数（`2026-09-24 23:24:58.2549524`）。

**进度输出的真实格式**（关键发现）：

```
$ 7zz a -t7z -mx9 -bsp1 -bso0 slow.7z big
 15% 40 + big/rand.bin\b\b\b...\b     \b\b...\b 21% 40 + big/rand.bin\b...
```

没有换行符，靠**退格原地擦除重写**。

> 这一点推翻了最初的假设。最初用小压缩包测试时只看到 `0%`，据此以为管道下进度不可用，
> 甚至写好了伪终端（pty）方案。换成 65MB 慢速压缩重测后，证明**管道下进度完全正常**。
> 于是删掉了 pty 代码，方案少了一个失败点。

**退出码**：0 成功、1 警告、2 致命错误；错误信息走 stderr，形如
`ERROR: Data Error in encrypted file. Wrong password?`。

## 4. 引擎自检

```
cd app
ARCHIVE_TEST_BINARY="$PWD/../build/bin/7zz" ARCHIVE_TEST_TMP="$PWD/../build/testtmp" \
  swift run --disable-sandbox --scratch-path ../build/app-build SelfTest
```

完整输出见 `docs/selftest-output.txt`，结论：

```
通过 56 ｜ 失败 0 ｜ 跳过 0 ｜ 用时 1.5s
```

`ARCHIVE_TEST_BINARY` 用绝对路径是硬性要求（见第 7 节 #5）：集成测试里的 `7zz`
以自己的临时目录为工作目录运行，相对路径会被解析到不存在的位置。运行器现在会把相对
路径按启动目录补全；若最终指向的文件仍不可执行，则**整个运行以失败结束**，不再退化成
「跳过 16 项、退出码 0」的假绿。

### 4.1 先修的是测试运行器本身（重要）

**最初报告的「48 通过 ｜ 0 失败」是不可信的。** 运行器在测试体正常返回时直接记为通过，
却从未检查断言记录下来的失败列表——只要断言不抛异常，失败就被静默吞掉。修正后同一批
测试的真实结果是 **43 通过 ｜ 5 失败**，暴露出下面三个真实缺陷。

这个问题本身的教训值得留下来：**一个会把失败算成通过的测试框架，比没有测试更危险**，
因为它提供的是虚假的信心。修正后的运行器在成功路径上也会检查失败列表，并且任何一项
失败都会让进程以非零码退出。

### 4.2 三个被掩盖的真实缺陷

| 缺陷 | 症状 | 根因 |
| --- | --- | --- |
| 进度解析贪婪匹配 | 缓冲区含两条进度时报告**较早**那条，进度条倒退、文件名变成一长串拼接文本 | 文件名的捕获组 `[^\n\r]*` 是贪婪的，会跨过后面的进度；取「最后一个匹配」实际只匹配到第一个 |
| UTF-8 解码器跨读取拼接错误 | `压缩` 解成 `压�` | 回退到首字节后，`cut` 指向首字节本身，切片时把整个字符切掉了 |
| `.tar.*` 解压只剥一层 | 解压 `.tar.gz` 得到的是一个 `.tar` 文件，拿不到原始文件 | `7zz x` 对 `.tar.gz` 只解外层，不会自动进入内层 tar |

对应的修复：

1. 先定位缓冲区里最后一个 `NN%`，再**只解析它之后的片段**；
2. 重写回退逻辑，未完整的序列整段留到下次读取；
3. 识别 `.tar.gz/.tgz/.tar.bz2/.tbz/.tar.xz/.txz/...`，先解到临时目录取出内层 tar，
   再把 tar 解到目标目录（临时目录在 defer 中清理）。

自检里新增了两类回归防护：**进度不得倒退**，以及 **tar.\* 三种格式必须解出真实文件、
不得残留中间 tar**。

### 4.2.1 关于 `.tar.gz` 到底测没测过

需要澄清一个容易含糊过去的地方：**修复之前，`.tar.gz` 并没有被真正测到。**

仓库里原本就有一条 `TAR.GZ 两段式往返` 测试，但它一直显示 ✓ ——那正是 4.1 描述的假绿。
它的断言 `期望 tarball，实际 ''` 一直在失败，只是从未被汇报。所以准确的说法是：
修复前 `.tar.gz` 有一条**假装测过**的测试，而 `.tar.bz2` / `.tar.xz` 连测试都没有。
三者都是在修好运行器之后才第一次获得有效的覆盖。

### 4.2.2 变异测试：证明这些断言真的有牙齿

「测试通过了」本身不能说明测试有效——一个恒真的断言也会通过。因此对 `.tar.*` 的修复做了
变异测试：临时关闭修复，确认断言**确实会失败**。

`isCompressedTar` 里留了一个仅在 `DEBUG` 生效的开关（发布版会被编译掉，成品不含任何
行为后门）：

```swift
#if DEBUG
if ProcessInfo.processInfo.environment["ARCHIVE_DISABLE_TAR_FIX"] != nil { return false }
#endif
```

关闭修复后运行：

```
✗ TAR.GZ 两段式往返且清理临时文件
✗ TAR.GZ / TAR.BZ2 / TAR.XZ 解压出真实文件而非中间 tar
  ✗ TAR.GZ 解压后未得到原始文件 — 期望 tarball，实际
  ✗ TAR.GZ 解压后不应残留中间 tar：[".simpleunzip-7CF986D5-….tar"]
  ✗ TAR.BZ2 解压后未得到原始文件 — 期望 tarball，实际
  ✗ TAR.BZ2 解压后不应残留中间 tar：["out.tar"]
  ✗ TAR.XZ  解压后未得到原始文件 — 期望 tarball，实际
  ✗ TAR.XZ  解压后不应残留中间 tar：["out.tar"]
通过 47 ｜ 失败 2
```

恢复修复后：

```
✓ TAR.GZ 两段式往返且清理临时文件
✓ TAR.GZ / TAR.BZ2 / TAR.XZ 解压出真实文件而非中间 tar
通过 51 ｜ 失败 0
```

发布版二进制的对应检查（`strings` 直接读二进制的字符串表）：

```
✓ 含 tar 解包修复（.simpleunzip-unwrap- 标记）
✓ 不含变异测试开关（已被 #if DEBUG 排除）
```

### 4.3 一处「测试写错、产品无辜」

「进度应当到达 100%」这条断言最初失败。直接抓取 `7zz` 输出后确认：**7-Zip 压缩时从不
报告 100%**，实测序列为 `0% → 37% → 73% → 76%` 然后清行。进度条走满是应用层在任务
完成时补的。断言据此改为检查「真实中间值 + 不倒退」，并记录了这一事实。

### 4.4 真实用户报告：`.tar.xz` 打开后只有一个条目

**报告**：`test/sample.tar.xz`（7.6 MB）无法正常解压，界面里的简介也不对。

**复现**：`7zz l -slt sample.tar.xz` 只报告**一个**条目 —— 121 MB 的中间 tar
`sample.tar`。所以浏览器显示成一行 `sample.tar`，看起来就是「简介错了」。
原因是 7-Zip 的 CLI 不会自动穿透压缩层（GUI 里双击才会进去），而 `.tar.xz` 的外层是 xz、
内层才是 tar。

**走过的弯路（值得记下来）**：为了不把 121 MB 的中间 tar 写到磁盘，我先实现了流式方案——
`7zz x -so` 输出 tar 到管道，另一个 `7zz l -slt -ttar -si` 从 stdin 读。shell 里验证可行
且字节精确，但放进应用后崩溃：

```
Terminating app due to uncaught exception 'NSFileHandleOperationException',
reason: '*** -[NSConcreteFileHandle fileDescriptor]: Bad file descriptor'
  ... -[NSConcreteTask launchWithDictionary:error:]
```

原因把**同一个 `Pipe` 对象**交给了两个 `Process`，Foundation 在第二次启动时描述符已失效。
我改写成了 POSIX `pipe()` + 各自独立的 `FileHandle`——但那是在为一个尚未证明必要的优化
不断加码：多进程管线、SIGPIPE、进程组、取消语义，每一个都是新的失败面，而换来的只是省掉
一次临时文件写入。

**最终采用的做法**：退回简单方案。把外层剥到临时文件，再对临时文件做 `l -slt` 或解压，
最后删除。

```
列表：357 个条目，类型 tar.xz，外层 7.6 MB
解压顶层：["sample"]
解压文件数：323
```

代价如实记录：列表一个 `.tar.*` 需要临时写入一份解压后的 tar（本例 121 MB，约 0.8 秒）。
超大归档会明显变慢，见 §6。

**同时修好的一件事**：这次报告暴露出我最初写的断言也不严谨——我断言「列表里不应有任何
以 `.tar` 结尾的条目」，但**这个归档里本来就有一个合法的 `sample/sample.tar` 文件**。
断言已改为检查形态（列表是否只剩中间 tar 这一个条目），而不是扩展名。

**验证方式**：新增了 `ARCHIVE_EXTRA_ARCHIVE` 诊断入口，可以对任意真实文件跑完整的
列表 + 解压往返。上面的数字就是用它跑出来的，不是合成测试。

覆盖范围：

- **解析层**：`-slt` 头部与条目、目录/文件区分、固实块缺失字段、7 位小数时间戳、
  加密识别、缺空行时的记录切分、目录树构建与中间目录补全。
- **进度层**：百分比/计数/文件名提取、同块多进度取最新、跨读取拆分的进度、
  退格清理、日志与错误分流、缓冲区上限、进度不倒退。
- **真实压缩包往返**：压缩 → 列表 → 解压全流程、ZIP 往返、TAR.GZ 两段式
  （并验证临时文件被清理）、只解压所选条目、macOS 垃圾文件排除。
- **压缩型 tar**：`.tar.gz` / `.tar.bz2` / `.tar.xz` 三种格式均解出真实文件且不残留中间 tar。
- **加密**：错误密码返回 `.wrongPassword`、正确密码可解、加密头在提供密码后才显示文件名。
- **取消**：48MB 压缩进行中取消，确认抛出 `.cancelled`。
- **中文与空格路径**：`中文 目录/带 空格 的文件.txt` 与 `归档 文件.7z` 完整往返。

## 5. 界面验证

### 遇到的障碍

终端**没有屏幕录制权限**。`screencapture` 只能拍到桌面壁纸：

- 截图中连浏览器、DSH 等已打开的窗口都不存在；
- 而 `CGWindowListCopyWindowInfo` 同时报告应用窗口 `onscreen=true`、`960x672`。

两者矛盾，说明是权限问题而非应用问题。

**授权后重测仍然失败。** 在系统设置中授予屏幕录制权限后复测：

```
$ screencapture -x -o -l <窗口ID> out.png
could not create image from window
```

这是权限未就绪的典型报错；全屏截图依旧只有壁纸，且输出字节数（5027122）与授权前的
壁纸截图**完全一致**。原因是已运行的进程不会热加载 TCC 授权——macOS 要求退出并重新
打开应用后才生效。所以本次自动化截屏这条路没有走通。

### 采用的替代方案

给应用加了离屏渲染模式：把视图装进真实的 `NSWindow`（定位在屏幕外 −30000），
再通过 `cacheDisplay(in:to:)` 截图。**首次尝试用裸 `NSHostingView` 是失败的**——
`List` 与 `NavigationSplitView` 这类 AppKit 桥接控件在脱离窗口时不会填充内容，
快照里侧边栏和文件列表是空的。放入窗口后才正常。

```
ARCHIVE_RENDER_PREVIEWS=build/previews \
ARCHIVE_PREVIEW_ARCHIVE=build/preview-archive.7z \
ARCHIVE_PREVIEW_DEMO=build/preview-demo \
  "dist/Simple Unzip.app/Contents/MacOS/SimpleUnzip"
```

产物见 `docs/previews/`，全部经过人工查看。这一过程**发现并修复了三个真实缺陷**：

1. `Form` 会把 `TextField` 的标题抽出当行标签，并把控件放到右侧值列，导致标签重复、
   输入文字贴右。用 `labelsHidden()` + 上置说明文字修正。
2. 压缩面板 640pt 高，加密与高级选项被挤出可视区。
3. 解压面板 470pt 高，**加密压缩包的密码输入框不可见**。

### 交互启动验证

```
$ open "dist/Simple Unzip.app"
$ pgrep -lf SimpleUnzip
14512 .../dist/Simple Unzip.app/Contents/MacOS/SimpleUnzip

$ <CGWindowListCopyWindowInfo>
owner=Simple Unzip layer=0 alpha=1.0 onscreen=true bounds=[Width: 960, Height: 672]
```

应用可正常启动并显示窗口，菜单栏包含自定义的「操作」菜单。

### 人工实测结果

自动化截屏走不通后，**由使用者在本机对应用做了人工测试**，结论：

- 窗口缩放：正常；
- 压缩与解压：正常。

这补上了离屏快照无法覆盖的交互部分。仍未覆盖的交互路径见下一节。

## 6. 明确未能验证的部分

诚实列出，避免高估交付质量：

- **自动化交互验证缺失**：拖放、键盘快捷键、滚动、深色模式等路径没有自动化覆盖，
  也没有操作录屏。窗口缩放与压缩解压已由人工实测确认（见上）。
- **未做签名与公证**：仅 ad-hoc 签名，本机可运行；拷给别人会被 Gatekeeper 拦截。
- **冷门格式未穷举**：加密归档、特殊分卷、ISO/WIM 等只验证了「能列出」的通用路径，
  没有逐个构造样本测试。
- **大文件与网络卷未压测**：最大只测到 48MB 的本地文件。
- **未做多显示器与深色模式的适配验证**：快照固定使用 `.aqua` 外观。

## 7. 复审修复记录（外部测试反馈）

一轮外部测试提交了 15 条「功能 bug」清单（按用户可感知的严重度排序）。逐条复核后，
**14 条在代码中确认存在并已修复，1 条未能复现**。下面按清单编号记录结论与验证方式，
未复现的那条也照实记录。

### 7.1 会静默丢文件的两条（同一根因，已修）

**#1 `commonAncestor` 缺少目录边界判断**（`ArchiveEngine.swift`）。

```
commonAncestor(/tmp/x/ab/f1.txt, /tmp/x/abc/f2.txt)
  期望 /tmp/x   实际 /tmp/x/ab        ← "/tmp/x/abc".hasPrefix("/tmp/x/ab") == true
```

本机用编译好的 7zz 复现过原始故障：两个「互为前缀」的兄弟目录一起压缩时，
引擎在错误的目录里以裸文件名执行，`abc/f2.txt` 根本没进包：

```
$ cd pref/ab && 7zz a -t7z bug.7z f1.txt f2.txt
WARNING: errno=2 : No such file or directory   f2.txt
Scan WARNINGS: 1
EXIT=1
$ 7zz l -slt bug.7z | grep '^Path ='
Path = f1.txt                                  ← abc/f2.txt 消失了
```

修法是加 `isContained(_:in:)`，按路径分隔符判断包含关系而不是裸 `hasPrefix`。

**#6 退出码 1（警告）一律当成功**（`ArchiveEngine.failure`）。这是 #1 之所以「静默」的
原因：7-Zip 用 1 表示「完成但有项目被跳过」，原实现 `case 0, 1: return nil` 直接吞掉。
实测一个无读取权限的文件：

```
WARNING: errno=13 : Permission denied   func/noperm.txt
WARNING: Cannot open 1 file     EXIT=1
```

现在写文件类命令（`a` / `x` / 拆 tar）把退出码 1 报为 `.completedWithWarnings`，任务以
**「有警告」**结束、弹出说明并列出被跳过的条目；只读命令（`l` / `t`）保持宽容——
一个良性警告不该让本来能正常浏览的压缩包打不开。

### 7.2 功能不可用（已修）

**#2 头部加密（`-mhe=on`）的压缩包在界面里打不开**。实测：

```
$ 7zz l -slt enc.7z     →  Enter password: / Break signaled，Path 条目 0，EXIT=255
$ 7zz l -slt -pPw123 enc.7z  →  正常列出
```

原代码把这种情况记进 `pendingPasswordArchive`，而全文没有任何读取方——用户看到
「需要密码」的弹窗，点掉之后没有任何输入框，只能重开。现在该状态驱动一个
`PasswordSheet`（新增 `Views/PasswordSheet.swift`），密码错误会重新提示；
成功打开后密码会被复用，解压面板与完整性校验不必二次输入。

### 7.3 静默出错与状态错乱（已修）

| # | 位置 | 处理 |
|---|------|------|
| 3 | `CompressionDraft.validationMessage` | 新增 `ArchiveFormat.holdsSingleItemOnly`（gz/bz2/xz），多文件或文件夹在选择格式后立刻拦截，不再把 `E_INVALIDARG` 抛给用户 |
| 7 | `RunningProcess.settleIfReady` | 取消标志只在该子进程确实没跑完（退出码非 0）时才报「已取消」；退出码 0 说明结果已落盘，必须报成功 |
| 8 | `ArchiveBrowserView` | 筛选条件变化时把选中集与当前可见行求交集，避免「解压所选」解出看不见的行 |
| 9 | `ExtractSheet.chooseDestination` | 目录选择面板改为定位到界面显示的**目标文件夹**本身（不存在则临时建、取消则回收空目录），不再默认落到父目录 |
| 10 | `DisplayFormat.bytes` | `nil`（未知）与 `0`（真实空文件）不再混同；筛选模式的行改为复用真实树节点，文件夹显示真实子树大小 |
| 11 | `DropZoneView` + `Panels.loadFileURLs` | 只有确实能读出文件 URL 时才接受拖放；读不出来则状态栏与弹窗明确说明，并补上 `public.file-url` 载荷的解码分支 |
| 12 | `SimpleUnzipApp.pullWindowsBackOnScreen` | 改用 `window.screen ?? NSScreen.main`，副屏窗口不再每次启动被拽回主屏并缩掉 40pt |

### 7.4 小毛病（已修）

- **#13**：切到不支持加密的格式时自动关闭「使用密码」开关，不再出现「提示要改格式、
  但开关是禁用状态」的死锁。
- **#14**：目标压缩包已存在时先弹确认（分卷压缩检查 `.001`）。

### 7.5 未复现与未修

- **#4「`scripts/` 全是 100644」：未能复现。** 本仓库的 git 索引里两个脚本都是
  `100755`，并且实测做了一次干净 clone：

  ```
  $ git ls-files -s scripts/
  100755 ... build-app.sh
  100755 ... fetch-source.sh
  $ git clone -q . /tmp/clonechk && ls -l /tmp/clonechk/scripts/
  -rwxr-xr-x  build-app.sh
  -rwxr-xr-x  fetch-source.sh
  ```

  该现象符合「用非 git 方式取到代码」（下载 zip、AirDrop、拷贝目录）时权限位丢失。
  已在 README 构建一节补上 `chmod +x scripts/*.sh` 的说明，未改动权限位本身。
- **#5 自测命令与「假绿」：已修。** `ARCHIVE_TEST_BINARY` 的相对路径在子进程里会被
  按临时工作目录解析，运行器现在先按启动目录补全为绝对路径；若显式指定的二进制不可
  执行，则抛 `FatalTestError` 让整轮运行失败（此前会退化成「跳过」并返回 0）。
  刻意写错路径的实测结果：`通过 37 ｜ 失败 19`，退出码 1。README 与本文档的示例命令
  已改用绝对路径。
- **#15「界面全中文硬编码、无本地化」：未修。** 完整本地化会触及每一个视图与文案，
  属于结构性改动而非 bug 修复，且需要英文文案校对。保留为已知限制。

### 7.6 新增回归测试

自检从 51 项增加到 56 项，新增的 5 项正对上面最容易复发的缺陷：

- `名字互为前缀的兄弟目录不会退化成其中一个`（单元）
- `退出码 1：只读命令宽容，写文件命令报警告`（单元）
- `互为前缀的兄弟目录同时压缩时不丢文件`（集成）
- `被跳过的条目以警告结束，不静默成功`（集成，用 `chmod 000` 制造真实警告）
- `头部加密的压缩包无密码时报告需要密码`（集成）

### 7.7 新界面的离屏验证

新增的两块界面用仓库既有的离屏渲染（`ARCHIVE_RENDER_PREVIEWS`，见第 5 节）验证，
产物已归档：

- `docs/previews/10-password-sheet.png`：头部加密压缩包的密码输入面板
  （标题、包名、说明、密码框、「取消 / 打开」，密码为空时「打开」为禁用态）。
- `docs/previews/11-task-warning.png`：任务行的「有警告」状态
  （橙色徽标 + 跳过说明 + 「在访达中显示」）。

渲染命令（用到包内 7zz 时通过 `ARCHIVE_BINARY` 指定）：

```bash
ARCHIVE_RENDER_PREVIEWS="$PWD/build/previews-review" \
ARCHIVE_PREVIEW_DEMO="$PWD/build/preview-demo" \
ARCHIVE_BINARY="$PWD/build/bin/7zz" \
"$PWD/build/app-build/debug/SimpleUnzip"
```

仍未自动化的交互（拖放、确认弹窗、多显示器拖动）只能人工确认，见第 6 节。
