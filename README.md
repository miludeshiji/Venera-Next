<div align="center">
  <img src="assets/readme_logo.png" alt="VeneraNext" width="200" />

  # VeneraNext — 个人自用分支

  ![Flutter](https://img.shields.io/badge/Flutter-3.41.4-02569B?logo=flutter&logoColor=white&style=flat-square)
  [![Release](https://img.shields.io/github/v/release/miludeshiji/venera-next?label=Release&color=10B981&style=flat-square)](https://github.com/miludeshiji/venera-next/releases)
  ![License](https://img.shields.io/badge/License-GPL--3.0-10B981?style=flat-square)
</div>

> [!CAUTION]
> **这是一个仅供维护者个人使用的非官方分支。**
>
> 本仓库按维护者自己的设备、数据和使用习惯开发，可能大量使用生成式 AI 参与设计、编码、测试、审查和文档编写，也可能进行范围较大、节奏较快、未经长期验证的激进修改。
>
> 本仓库不保证稳定性、向后兼容性或与上游同步，不保证兼容 VeneraNext、Venera、第三方扩展、既有配置、数据文件、备份或其他项目。切换版本、导入数据或连接 WebDAV 前，请自行备份重要数据并确认能够恢复。

## 仓库定位

这个仓库不是 VeneraNext 或 Venera 的官方发行版，也不以成为通用下游发行版为目标。维护优先级只取决于维护者的个人需求；功能、接口、数据结构和交互可能在没有迁移期或弃用期的情况下发生变化。

如果你只是寻找稳定版本、官方构建或面向公众的使用支持，请优先访问直接上游：

- [CyrilPeng/Venera-Next](https://github.com/CyrilPeng/Venera-Next)
- [venera-app/venera](https://github.com/venera-app/venera)

本仓库会不定期合并上游更新，但不承诺及时跟进，也不保证个人修改能与后续上游改动无冲突共存。

## Fork 来源

本仓库的继承关系为：

```text
venera-app/venera
        ↓
CyrilPeng/Venera-Next
        ↓
miludeshiji/Venera-Next（本仓库）
```

- 原始项目：[venera-app/venera](https://github.com/venera-app/venera)
- 直接上游：[CyrilPeng/Venera-Next](https://github.com/CyrilPeng/Venera-Next)
- 个人分支：[miludeshiji/Venera-Next](https://github.com/miludeshiji/Venera-Next)

感谢原项目和直接上游维护者的设计、实现与持续维护。本仓库中的大量基础能力来自上述项目；个人修改不代表上游立场，也不应被视为上游支持的功能。

## 当前个人修改

当前较主要的个人修改是 Bangumi 阅读进度同步：

- 使用 Bangumi Access Token 连接账号并绑定漫画条目。
- 阅读完成后单向上传进度，并在失败后保存设备本地重试状态。
- 手动修改进度、评分以及“想读、在读、读过、搁置、抛弃”收藏状态。
- 在详情页区分条目总话数、总卷数、当前阅读章节和远端同步进度。

完整变更见 [CHANGELOG.md](CHANGELOG.md)。这些功能主要针对维护者自己的使用方式实现，不构成兼容性或长期维护承诺。

## 基础能力概览

本仓库继承 VeneraNext/Venera 的主要阅读器能力，包括：

- Android、iOS、Windows、Linux 和 macOS 跨平台 Flutter 应用。
- 画廊、连续和瀑布流等阅读模式，以及跨章节阅读、双页拆分和阅读进度记录。
- 本地漫画目录及 CBZ、ZIP、7Z、PDF、图片型 EPUB 等导入能力。
- JavaScript 漫画源扩展运行环境。
- 收藏、历史、阅读时长、图片收藏、下载和追更。
- WebDAV 应用数据同步、漫画归档和远端漫画库。

这里仅列出能力范围，不代表本分支对所有平台、格式、扩展或服务均完成验证。

## 使用与构建

本仓库不承诺提供持续可用的公开安装包、自动更新或版本迁移支持。建议只在理解风险并完成数据备份后自行构建。

项目当前要求 Flutter `3.41.4`，依赖必须按锁文件解析：

```bash
flutter pub get --enforce-lockfile
flutter run
```

提交或维护代码前，至少运行：

```bash
python .github/scripts/check_structure_imports.py
python -m unittest discover -s .github/scripts/tests -p "test_*.py"
flutter analyze --no-pub
flutter test --no-pub
git diff --check
```

更完整的环境、构建和平台要求见：

- [构建与开发](doc/development/build.zh.md)
- [项目结构约定](doc/architecture/project_structure.zh.md)
- [依赖治理](doc/development/dependencies.zh.md)
- [完整文档索引](doc/README.md)
- [本地漫画导入说明](doc/user/import_comic.zh.md)

## 反馈范围

可以提交与当前分支直接相关、能够稳定复现的问题，也可以提交目标明确、范围较小的 Pull Request。但这是个人维护仓库：是否处理、何时处理以及是否接受修改均不作保证。

请在反馈中提供：

- 当前 commit 或版本；
- 操作系统和 Flutter/应用环境；
- 最小复现步骤；
- 实际结果、预期结果和相关日志；
- 是否能够在直接上游复现。

本仓库不提供、内置、托管、推荐或维护任何漫画源，也不处理源站内容、具体作品可用性、章节缺失、图片失效、账号限制或版权问题。此类问题应反馈给对应扩展、源站或服务提供者。

## 风险与数据

- AI 参与不代表代码已经得到完整人工审计或长期验证。
- 上游更新与个人修改可能产生语义冲突，即使 Git 合并没有冲突也不代表行为兼容。
- WebDAV 同步可能传播配置和数据变更；试用前应保留独立备份。
- 新版本可能无法直接读取旧版本数据，旧版本也可能忽略或误解新字段。
- 本仓库不对数据丢失、服务不可用、扩展失效或第三方兼容问题承担保证责任。

## 许可

本项目及其衍生修改遵循 [GPL-3.0](LICENSE) 许可。使用、修改和再分发时，请同时遵守原项目、直接上游及所用第三方依赖的许可要求。

软件按现状提供，不附带任何明示或默示担保。