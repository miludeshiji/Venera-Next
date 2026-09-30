# Git 依赖接管与替换审计（2026-09-30）

English: [dependency_audit.en.md](dependency_audit.en.md) · [治理规则](dependencies.zh.md) · [机器可读清单](git_dependencies.json)

本文档记录 VeneraNext 当前 Git 依赖的来源审查、定制理由与维护责任。完整 commit、仓库 URL、包路径与状态以机器可读清单 `doc/development/git_dependencies.json` 为准。

## 已完成的治理变更

- **移除 `flutter_to_debian`**：Debian 打包改用项目独立的 `debian/build.py` 脚本直接调用系统 `dpkg-deb` 工具，输出目录规范为 `build/linux/{x64,arm64}/release/debian`，连带移除仅打包使用的传递依赖 `mime_type`。CI 不再需要 `dart pub global activate -s git flutter_to_debian`。
- **建立机器可读清单与自动化检查器**：新增 `doc/development/git_dependencies.json` 清单与 `tool/check_git_dependencies.dart`。代码分析工作流在锁定依赖获取后运行检查器，严格校验所有直接依赖、传递 Git 包的 URL、ref、resolved-ref、包路径及锁文件一致性。
- **明确来源与责任边界**：本项目保持自有依赖策略与 `miludeshiji` 仓库身份，保留 `venera-app` 来源固定 commit，不转向上游个人仓库；清单中的 `maintained-fork` 标识当前保留的定制分支，不代表本项目维护这些外部仓库；本项目维护者负责固定版本（pin）审查与兼容性把关。

## 每项 Git 依赖的审查结论

| 依赖 | 来源与版本 | 现状与替换要求 |
|---|---|---|
| `flutter_qjs` | `venera-app/flutter_qjs` (`8feae95`) | 包含 QuickJS-NG 迁移、JS 数值与 NaN 转换修复、Apple/Android 平台构建适配。保留定制分支；替换需验证运行时对象生命周期、异步 Promise 与跨平台构建。 |
| `photo_view` | `venera-app/photo_view` (`a1255d1`) | 阅读器依赖定制的 `getInitialScale` 及手势/动画定位扩展。保留定制分支；替换需重新适配阅读器缩放、双页与自动阅读。 |
| `scrollable_positioned_list` | `venera-app/flutter.widgets` (`09e756b`) | 包含阅读器专用的 `scrollControllerCallback` 与 `scrollBehavior` 回调支持。保留定制分支；替换需验证长章节跳页与滚动同步。 |
| `desktop_webview_window` | `venera-app/flutter_desktop_webview` (`7801fc5`) | 包含桌面端代理、Linux libsoup 与 Windows ARM64 适配。许可证待核实（license-review）；替换前需评估清晰授权方案。 |
| `flutter_inappwebview` | `venera-app/flutter_inappwebview` (`3ef899b`) | 6.2.0-beta.3 分支并修复 `GraphicsContext` 释放泄漏，连同 6 个平台子包共同锁定。整仓保留；替换需验证网页登录、Cookie、代理及销毁重建。 |
| `webdav_client` | `venera-app/webdav_client` (`2f669c9`) | 包含底层 `RHttpAdapter` 适配器集成、认证、重定向及目录处理。保留定制分支；替换需验证 native rhttp 网络传输。 |
| `flutter_saf` | `venera-app/flutter_saf` (`d7c1e55`) | 提供 Android 持久目录授权与 isolate 内 IO override 机制。许可证待核实（license-review）；替换需覆盖后台读写与 SAF 隔离。 |
| `flutter_7zip` | `venera-app/flutter_7zip` (`b333447`) | 7z/CB7 导入与 ZIP 回退核心依赖。许可证待核实（license-review）；先保留固定 commit，评估等价实现。 |
| `lodepng_flutter` | `venera-app/lodepng_flutter` (`6216834`) | 原生 PNG 编码指针与 finalizer 内存管理。许可证待核实（license-review）；替换需验证大图编码性能与内存泄漏。 |

## 验证事实与边界说明

- **Debian 打包**：在 WSL Debian GNU/Linux 环境下运行 `test_debian_package.py`，6/6 项测试通过，包含真实系统 `dpkg-deb` 对 amd64 与 arm64 架构安装包的生成、解包、ELF64 架构检查与 dpkg 真实版本排序。注意：此项验证基于测试 fixture bundle，不构成真实 Linux 桌面 GUI 运行的充分证明。
- **依赖检查器**：本地与 CI 执行 `dart tool/check_git_dependencies.dart`，输出 `inventory matches declarations and lockfile`，零错误。
- **锁文件一致性**：使用指定的 Flutter 3.41.4 环境，以 `pub.dev` 官方源成功执行 `flutter pub get --enforce-lockfile`，严格保留全部锁定版本。
- **静态分析与代码门禁**：项目结构 import 门禁完全通过；`flutter analyze` 无错误、无警告（包含 24 条既有遗留 info，不宣称绝对无警告 clean lint）。
- **未验证项目**：本轮未在真实 Android 物理机/SAF 真实环境、真实 Linux 桌面运行或线上 GitHub Actions 执行构建，文档不宣称这些环境已经过验证。
