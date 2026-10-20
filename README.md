# 微信多开（WeChatMulti）for Mac

菜单栏小程序，一键创建多个**数据完全隔离**的微信实例。每个实例都是一个独立的 `.app`，放在 `~/Applications`，可以从启动台、Spotlight、Dock 直接双击打开。

## 原理

1. APFS `clonefile` 克隆 `/Applications/WeChat.app`（约 0.1 秒）
2. 改写 bundle id（主程序 + 5 个嵌套组件）和显示名「微信 N」，图标叠加编号角标
3. 在 Info.plist 写入 `LSEnvironment.CFFIXED_USER_HOME`，把数据根钉到独立目录
4. 禁用 Sparkle 自动更新，防止实例自行升级覆盖注入
5. 去沙盒、由内向外 ad-hoc 重签全部 Mach-O
6. 校验通过后与旧 App 原子互换（`renamex_np` RENAME_SWAP），再 `lsregister -f` 刷新 LaunchServices 缓存

全部步骤都在暂存区完成，任何一步失败，正在用的实例都不受影响。

官方微信本身不会被改动。详细设计见 [产品方案.md](产品方案.md)。

## 安装

到 [Releases](../../releases/latest) 下载 `WeChatMulti-x.y.z.dmg`，把「微信多开」拖进「应用程序」。

未经公证，首次打开前执行一次：

```bash
xattr -dr com.apple.quarantine /Applications/微信多开.app
```

**要求**：macOS 14+ · Apple Silicon · 已安装官方微信 · APFS 磁盘

## 使用

点菜单栏 💬 图标：

- **新建实例…**：生成「微信 1」「微信 2」……，之后直接从 Dock / 启动台双击即可
- **全部启动 / 全部退出**
- 每个实例的子菜单：启动、退出、隔离自检、打开数据目录、重建、删除
- **微信升级后**：菜单顶部会提示「N 个实例待重建」，点「全部重建」即可，登录态和聊天记录不丢
- **登录时启动**

> ⚠️ 实例必须通过 LaunchServices 启动（Dock、启动台、Finder、菜单栏）。从终端直接运行 `Contents/MacOS/WeChat` 不会注入数据根，数据会写进真实的 `~/Documents`。

## 命令行

```bash
/Applications/微信多开.app/Contents/MacOS/WeChatMulti <命令>
```

| 命令 | 说明 |
|---|---|
| `doctor` | 环境体检 |
| `list` | 列出实例及状态 |
| `create [ID]` | 创建实例 |
| `start ID` / `stop ID` | 启动 / 退出 |
| `rebuild ID` | 用当前官方版本重建（保留数据） |
| `rebuild-all` | 重建所有落后于官方版本的实例 |
| `check [ID]` | 隔离自检 |
| `delete ID` | 删除实例及数据 |
| `version` | 版本号 |

## 目录

| 位置 | 内容 |
|---|---|
| `~/Applications/微信 N.app` | 实例 App |
| `~/Library/Application Support/WeChatMulti/instances/NN` | 实例数据（登录态、聊天记录） |
| `~/Library/Application Support/WeChatMulti/config.json` | 实例注册表 |
| `~/Library/Application Support/WeChatMulti/logs/` | 运行日志 |

## 从源码构建

```bash
./build.sh
open .cache/scratch/release/WeChatMulti.app
```

推送 `v*` 标签后，GitHub Actions 会在 macOS 上编译、打包 dmg 并发布 Release。

## 风险

- 修改客户端、去掉沙盒可能违反微信用户协议，**请勿在高价值账号上使用**
- 实例没有 App Sandbox 保护，只登录你信任的账号
- 不碰微信任何业务逻辑：不做消息自动化、群发、聊天记录解密
