# NekoRemote（猫娘视频遥控器）

菜单栏小工具：打游戏时用键盘控制另一块屏幕上浏览器里播放的视频。

## 支持的游戏

判断依据是前台 App 的名称或 Bundle ID 是否命中关键词列表（菜单里可编辑，逗号分隔）。
默认包含：

| 关键词 | 对应游戏 |
|---|---|
| `原神`、`Yuanshen` | 原神（PlayCover 版） |
| `崩坏`、`星穹铁道`、`hkrpg` | 崩坏：星穹铁道（PlayCover 版） |

星穹铁道在 PlayCover 下的真实进程名是 `hkrpg`、Bundle ID `com.miHoYo.hkrpg`；
原神是 `Yuanshen` / `com.miHoYo.Yuanshen`。中文界面名和进程名不一致，
所以两种都放了进去。

## 按键

| 按键 | 作用 |
|---|---|
| **Tab** | 暂停 / 继续 |
| ← | 快退 |
| → | 快进 |

步进可在菜单里改（3 / 5 / 10 / 15 / 30 秒）。

## 定稿状态（2026-11-20 20:11）

**已冻结。不要再重新编译或重新 codesign。**

- 定稿 CDHash：`86cdfd5d66186270c2e709af15c4f3870b82a008`
- 整包备份：`Release/NekoRemote.app`（哈希与安装中的一致）
- 单文件备份：`Release/NekoRemote-final`
- 安装位置：`~/Applications/NekoRemote.app`

重新签名会改变 CDHash，macOS 的「辅助功能」「输入监控」「自动化」授权
都绑定哈希，一变就失效。

**要恢复定稿版本**：

    rm -rf ~/Applications/NekoRemote.app
    cp -R ~/Projects/NekoRemote/Release/NekoRemote.app ~/Applications/NekoRemote.app
    open ~/Applications/NekoRemote.app

## 为什么是 Tab，不是 Caps Lock

外接键盘切到 Mac 模式后，短按 Caps Lock 被系统拿去切换输入法，
长按才切换大小写，程序只能收到长按后的事件，做不了单击触发。
右 Option 在这台机器上始终收不到事件（原因未查明），实际测试无效。
Tab 注册为系统热键后一次按下只触发一次，且实测不发生焦点跳动，
因为热键被系统独占，浏览器根本收不到。

**副作用**：App 运行期间 Tab 被全局独占，在 Finder、编辑器、网页表单里
按 Tab 都不再有效果。退出 App 即恢复。使用者已知悉并接受。

## 实现要点

- **Carbon RegisterEventHotKey** 注册 Tab 与 ← →，每次按下触发一次。
- **Caps Lock 已完全移除**（包括 Event Tap 里那份，曾导致双重触发）。
- **CGEventTap 可选**：启动时用 `AXIsProcessTrusted` +
  `CGPreflightListenEventAccess` 检查，都拿到才启动；它负责吞掉 Tab
  和方向键，防止网页再收一次。
- 浏览器探测结果缓存 20 秒，避免每次按键都发 Apple Events 触发授权弹窗。

## 已知限制

- 没有开发者证书，只能 ad-hoc 签名。
- 每次重新编译签名都要重新授权辅助功能。

## 构建

    swift build
