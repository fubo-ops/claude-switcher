# Claude 切换器 · Fail-Closed 账号环境管理器

> 14 项环境审计不过，就物理上不让 Claude 启动。多账号快照隔离、Kill-Switch 断网急停、菜单栏实时状态。

- 平台：macOS（稳定） / Windows（Beta） / Linux（Beta）
- 维护者：[@zzc920-art](https://github.com/zzc920-art)
- 许可：MIT（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）

---

## 为什么需要它

AI 平台的风控早已不只看 IP：时区、Locale、DNS 出口、WebRTC 候选、设备指纹、行为序列都会被画像。
绝大多数封号不是“你做错了什么”，而是某个没意识到的场景里，真实出口 IP 悄悄溜出去了一次。

本项目的立场是 **Fail-Closed（故障即断）**：把安全约束做进系统，而不是依赖“用户记得”。

## 核心能力

| 能力 | 说明 |
|---|---|
| **14 项环境审计** | 代理内核 / TUN / 出口 IP / IP 一致性 / 时区 / 地区 / IPv6 / DNS / WebRTC / 保镖 / 置顶路由 / 客户端语言 / ASN / 生态可达性，任一不过拒绝启动 |
| **Kill-Switch** | root 守护进程每 10s 巡检，隧道中断即刻终止 Claude，把裸连窗口压到秒级 |
| **多账号快照隔离** | A/B 账号各自持有独立 OAuth 凭据与本地状态，切换时原子封存/载入（APFS clonefile COW） |
| **配置漂移自愈** | 时区/代理配置被系统或其他软件改动后自动回滚并留痕 |
| **WebRTC 泄漏探针** | 纯标准库手写 STUN 协议栈，多节点交叉验证，不依赖浏览器 |
| **设备指纹体检** | 字体地区特征、GPU、虚拟机检测（`fingerprint`） |
| **代理只读诊断** | 不启动 Claude、不改系统，仅验证指定代理到 Claude 网页/API 的传输（`diagnose-proxy`） |
| **网络自动恢复** | 用户态守护进程每 10s 巡检，隧道异常中断 15s 后自动重连代理（scutil → 拉起客户端），失败每 20s 重试，5 分钟内有效 |

### v2 新增（本仓库）

- **菜单栏常驻彩色盾牌**：绿=全部通过、黄=有告警、红=有失败、蓝=检查中；tooltip 显示账号与计数
- **菜单栏面板**：状态摘要、通过/告警/失败计数、上次检查时间、重新检查、打开主窗口、切换 A/B、退出
- **每 60 秒后台静默自检**，窗口不闪、状态实时同步
- **检查逐行「扫描点亮」动画** + 流动扫描条 + 实时耗时
- **网络自动恢复**：断网后无需人工介入，`local.claude-netguard` 每 10s 巡检，15s 未恢复即自动重连并留痕（`~/Library/Logs/claude-netguard.log`）
- **单实例**：重复启动自动激活已有实例
- 关窗不再退出，切换完成后只收窗口（菜单栏常驻，⌘Q 退出）

## 系统要求（macOS）

- macOS 13+（已在 macOS 27 / Apple Silicon 验证）
- 代理客户端：Clash Verge / Shadowrocket / sing-box / ClashX / Surge 任一，TUN 可用
- [Claude 桌面版](https://claude.ai/download) 安装在 `/Applications/Claude.app`
- `python3`（Xcode Command Line Tools 自带）
- 当前出口 IP 不在中国大陆（安装器会按出口自动锁定国家/时区/地区格式，CN 出口会拒绝安装）

> 仅安装 Command Line Tools（没有完整 Xcode）也能编译本 App：macOS 26/27 的 `@State` 宏问题已在源码中规避。

## 安装（macOS）

```bash
git clone https://github.com/fubo-ops/claude-switcher.git
cd claude-switcher
```

然后双击 `installer/安装.command`（或在终端执行）。安装器会自动：

1. 识别代理客户端与代理组
2. 按出口 IP 锁定 `国家 / 时区 / 地区格式`
3. 安装核心脚本到 `~/.local/bin/claude-switch.sh`
4. 现场编译 `Claude切换器.app` 到桌面
5. 安装 root 守护进程（Kill-Switch / 时区看门狗）与用户态自动更新
6. 跑一遍 14 项自检

安装过程会弹一次 macOS 授权框（安装守护进程 + 锁时区 + 关 IPv6），输入开机密码即可。

## 使用

1. 双击桌面「Claude切换器」→ 等 14 项检查
2. 全绿 → 选账号 A（首次会把当前登录收编为 A）或 B
3. 之后 A/B 随切随用；换国家节点后先跑一次 `set-region`
4. 菜单栏盾牌随时可看状态、重查、切号

命令行：

```bash
~/.local/bin/claude-switch.sh check          # 静默总检
~/.local/bin/claude-switch.sh checkdetail    # 14 项逐项
~/.local/bin/claude-switch.sh switch A|B     # 切换账号
~/.local/bin/claude-switch.sh fix            # 一键修复
~/.local/bin/claude-switch.sh set-region     # 换地区后重锁
~/.local/bin/claude-switch.sh fingerprint    # 设备指纹体检
~/.local/bin/claude-switch.sh update         # 手动更新
```

## Web 环境检测（零安装）

手机/平板浏览器直接打开：<https://fubo-ops.github.io/claude-switcher/>
纯前端检测出口 IP / 地区一致性 / WebRTC / IPv6 / DNS / 浏览器指纹，不上传任何数据。

## Windows 版（Beta）

见 [`windows/README.md`](windows/README.md)：PowerShell 核心 + WPF 界面，管理员运行安装器，行为与 macOS 版一致。

## Linux 版（Beta）

见 [`linux/README.md`](linux/README.md)：bash 核心 + systemd 用户单元 + 终端菜单。Claude 官方无 Linux 桌面版，账号切换作用于浏览器配置目录。

## 项目结构

```
app/main.swift          # SwiftUI 界面（单文件，菜单栏 + 窗口）
core/claude-switch.sh   # 核心逻辑：审计/切换/修复/诊断
core/stun-probe.py      # STUN 探针（纯标准库）
daemons/                # Kill-Switch / 时区看门狗 / 自动更新 launchd 模板
installer/              # macOS 安装/卸载
windows/ linux/         # Windows / Linux 移植版（Beta）
docs/                   # Web 检测页（GitHub Pages）
scripts/gen-sums.sh     # 重新生成 SHA256SUMS
tests/                  # 隔离回归测试
```

自动更新：`update --auto` 每 12 小时检查一次，按 `SHA256SUMS` 校验工件，失败自动回滚。
网络自动恢复：用户态 LaunchAgent `local.claude-netguard`（10s 周期），日志 `~/Library/Logs/claude-netguard.log`。

## 安全边界

- Kill-Switch 是**进程级急停**，不是防火墙级保证，巡检周期内存在固有 TOCTOU 窗口
- 本项目不提供代理/节点/账号，不绕过目标平台服务条款
- 守护脚本安装在 root 所有的 `/Library/Application Support/claude-switcher/`，用户态不可写
- 发现问题请走 GitHub Issues；安全类问题请私下联系维护者

## 来源与许可

MIT License。本项目包含来自开源项目 `claude-switcher` 的代码与设计，原始版权声明保留在 [LICENSE](LICENSE) 中，衍生说明见 [NOTICE](NOTICE)。本仓库的修改与新增功能版权归 zzc920-art 所有。
