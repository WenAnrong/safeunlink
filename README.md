# safeunlink — Linux 删除前占用检查 (阶段 2: 常驻 daemon + GUI 弹窗)

系统级"删除拦截器": 删除文件时, 先检查是否有**其他进程**仍在使用该文件
(fd / mmap / cwd / exe), 有则按模式处理:

- **warn** — 提示后继续删除 (终端: 红色文字; 无终端的 GUI 程序: 弹系统通知)
- **ask** — 交互确认 (终端: `y/N`; 无终端的 GUI 程序: daemon 弹 zenity 图形框)
- **block** — 提示并直接拒绝 (`EBUSY`)

## 功能

- **劫持删除**: `unlink` / `unlinkat` / `remove` / `rmdir` (真删)
- **劫持移入回收站**: `rename` / `renameat` / `renameat2` 且目标位于
  `~/.local/share/Trash/files`(XDG 规范)时, 同样按占用检查处理 ——
  覆盖文件管理器"删除"(实际是移入回收站)的场景
- 占用检测、三档模式、终端红字、GUI 弹窗/通知、豁免机制、fail-open、
  紧急开关 (详见下文)

## 原理

Linux 允许删除"被打开"的文件(进程继续用已删除的 inode), 没有任何内核
机制提供删除前回调, 所以拦截由 **LD_PRELOAD 共享库** + **常驻守护进程** 协作:

1. 库劫持 `unlink` / `unlinkat` / `remove` / `rmdir`
2. 按 inode 检查占用, 优先查 daemon(unix socket, 所有进程共享一份快照);
   daemon 不可用时回退为库内自带的快照扫描
3. 快照 = 一次全量扫描 `/proc/*/fd`、`maps`、`exe`、`cwd` 构建的
   "所有进程持有的 inode" 哈希集合, 每次删除 O(1) 查询, 默认每 2 秒重建
   (`ttl`), 因此 `rm -rf` 批量删除不会逐文件全盘扫描
4. ask 模式无终端时, 库把询问请求发给 daemon, daemon 弹 zenity 图形框,
   把用户决定返回给库; warn/block 模式无终端时发系统通知

## 构建与测试

```bash
make          # 构建 libsafeunlink.so / safeunlinkd / 测试辅助
make test     # 32 项测试 (含 daemon 协议、GUI 回退、批量/链接/豁免场景)
```

## 安装与卸载 (Debian/Ubuntu)

```bash
./install.sh            # 自动检测依赖→自动构建→安装→启动 daemon→自启→rm 别名
./uninstall.sh          # 一键卸载 (保留仓库源码)
```

`install.sh` 会: 校验系统为 Debian/Ubuntu 系列 → 缺失 `gcc`/`make`/`libc6-dev`
时自动 `apt-get install build-essential`(可选装 `zenity`/`libnotify-bin` 支持
图形弹窗)→ 构建 → 安装到 `/usr/local`(目标路径不可写时自动用 `sudo`)→
生成 `/etc/safeunlink.conf`(已存在则保留)→ 启动守护进程 → 添加图形会话自启
(`~/.config/autostart/safeunlinkd.desktop`)→ 向 `~/.bashrc` 添加 `alias rm='safe-rm'`。
**安装后开个新终端即可直接用 `rm`。**

可选参数 / 环境变量:

| 项 | 作用 |
|---|---|
| `--no-gui` | 不安装 zenity / libnotify-bin |
| `--no-alias` | 不修改 ~/.bashrc |
| `--no-autostart` | 不添加图形会话自启 |
| `--no-install-deps` | 不自动 apt 安装缺失依赖 (仅提示) |
| `PREFIX=/path` | 安装前缀 (默认 /usr/local) |
| `SAFEUNLINK_CONF=/path` | 配置文件路径 (默认 /etc/safeunlink.conf) |
| `uninstall.sh --keep-config` | 卸载时保留配置文件 |

## 用法

```bash
# 1. 启动守护进程 (GUI 弹窗/通知/共享快照需要它)
bin/safeunlinkd start        # 后台运行; stop / status 同理
#     (也可前台调试: bin/safeunlinkd run)

# 2. 按需启用拦截
bin/safe-rm important.txt    # 或:
LD_PRELOAD="$PWD/build/libsafeunlink.so" rm important.txt

# 3. 别名 (加到 ~/.bashrc)
alias rm='safe-rm'
```

安装到系统 (`make install` 后, `LD_PRELOAD=/usr/local/lib/libsafeunlink.so`):

> ⚠️ 全局注入 (`/etc/ld.so.preload`) 会让**所有**程序受拦截, 风险高;
> 建议按需启用或只对特定程序注入。

## 让图形文件管理器也受拦截 (阶段 2 的核心场景)

文件管理器删除时没有终端, 库里会走 daemon 弹窗。前提是文件管理器进程
加载了本库。两种方式:

**方式 A (推荐, 只影响目标程序)** — 覆盖 .desktop 启动项:

```bash
cp /usr/share/applications/org.gnome.Nautilus.desktop ~/.local/share/applications/
# 编辑该副本, 把 Exec= 改为:
#   Exec=env LD_PRELOAD=/usr/local/lib/libsafeunlink.so /usr/bin/nautilus %U
```

Thunar / Dolphin 同理 (改各自的 .desktop)。先 `make install` 把库放到
`/usr/local/lib`。

**方式 B (全局)** — 需要 root, 影响所有程序:

```
# /etc/ld.so.preload 写入一行:
/usr/local/lib/libsafeunlink.so
```

之后删除被占用文件时, 文件管理器会弹出图形询问框 (ask 模式) 或系统通知
(warn/block 模式)。

## 配置

环境变量(优先级最高):

| 变量 | 取值 |
|---|---|
| `SAFEUNLINK_MODE` | `warn` / `ask` / `block` (库) |
| `SAFEUNLINK_EXEMPT_PROCS` | 豁免"执行删除的进程"名, 逗号分隔 (库) |
| `SAFEUNLINK_EXEMPT_PATHS` | 豁免路径前缀, 逗号分隔 (库) |
| `SAFEUNLINK_TTL` | 占用快照有效期秒数, `0` = 每次全盘扫描 (库/daemon) |
| `SAFEUNLINK_TRASH` | `0` 关闭回收站拦截; 默认开启 (库) |
| `SAFEUNLINK_TRASH_DIR` | 覆盖回收站文件目录 (默认 `$XDG_DATA_HOME/Trash/files` 或 `~/.local/share/Trash/files`) |
| `SAFEUNLINK_DISABLE` | 非空 = 完全放行, 紧急开关 (库) |
| `SAFEUNLINK_ANSWER` | 无终端时 ask 的预置回答: `y` / 其他 = 取消 (库) |
| `SAFEUNLINK_COLOR` | 非空且非 `0` = 强制输出 ANSI 颜色 (库) |
| `SAFEUNLINK_SOCKET` | 覆盖 daemon socket 路径 (库/daemon) |
| `SAFEUNLINK_NO_DAEMON` | 非空 = 库完全不走 daemon, 只用本进程扫描 |
| `SAFEUNLINK_DIALOG` | `zenity` / `notify` / `none` (daemon) |
| `SAFEUNLINK_LOG` | daemon 日志路径 (daemon) |
| `SAFEUNLINK_CONFIG` | 指定配置文件路径 (库/daemon) |

配置文件(示例见 `etc/safeunlink.conf`, 查找顺序:
`~/.config/safeunlink.conf` → `/etc/safeunlink.conf`):

```ini
mode = ask
exempt_procs = apt,apt-get,dpkg,snap,flatpak
exempt_paths =
ttl = 2
trash = on       # 回收站拦截: on/off
dialog = zenity     # zenity | notify | none
log = auto          # auto | none | 路径
socket = auto       # auto | 路径
```

内置豁免: `/proc`、`/sys`、`/run` 及所有字符/块设备节点。
"占用者"是执行删除的进程自身时不提示(符合"其他程序"的语义)。

## daemon 协议 (供二次开发)

单行文本协议, 仅接受同 uid 连接 (`SO_PEERCRED`):

```
PING\n                   → PONG <pid>\n
CHECK <pid> <dev> <ino>\n → FREE\n | HELD <pid> <comm> ...\n | ERR\n
ASK <pid> <text>\n       → YES\n | NO\n
NOTIFY <text>\n          → OK\n
QUIT\n                   → BYE\n (退出)
```

## 设计原则与已知限制

- **fail-open**: 任何异常(路径解析失败、`/proc` 不可读、daemon 不可用、
  弹窗失败)一律放行, 绝不阻塞正常文件操作; 弹窗失败会写日志
- **快照窗口**: 占用检查基于最多 `ttl` 秒前的快照, 刚打开的文件可能漏报;
  需要最精确时 `SAFEUNLINK_TTL=0`
- **GUI 依赖**: daemon 弹窗需要 zenity 与用户的 DISPLAY; 无图形环境时
  ask 回退为"通知+放行" (日志记录)
- **绕过方式**: setuid 程序、静态链接二进制不受 `LD_PRELOAD` 影响;
  后续可用 FUSE / 内核 LSM 兜底 (见路线图)
- **线程/进程**: 快照构建期间持内部锁; fork 后子进程若恰逢快照重建可能
  短暂等待 (低概率, 已 fail-open 兜底)

## 路线图

- [x] 阶段 1: 终端 MVP (红色提示 / 交互确认 / 豁免 / 快照扫描)
- [x] 阶段 2: 常驻 daemon — unix socket 共享快照、zenity 图形询问框、
      notify-send 系统通知、日志、配置
- [x] 回收站: 文件管理器"删除"(rename 到 Trash/files)同样拦截

后续不做扩展 (整活项目到此为止) :)
