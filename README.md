# safeunlink — 删除前检查"文件是否被占用"

删除文件前, 先检查是否有**其他进程**仍在使用该文件 (fd / mmap / cwd / exe)。
被占用时: **只提示, 不允许删除** —— 一律阻止 (`EBUSY`), 没有"仍然删除"的选项:

- **终端** (`rm` 等): 红色文字提示占用者, 直接阻止删除
- **图形界面** (文件管理器等, 无终端): 弹 zenity 提示框, 直接阻止删除

覆盖两种删除方式:

- **真删**: `unlink` / `unlinkat` / `remove` / `rmdir`
- **移入回收站**: 文件管理器"删除"实际是 `rename` 到 `~/.local/share/Trash/files`,
  `rename` / `renameat` / `renameat2` 目标命中回收站时同样检查

## 原理

Linux 允许删除"被打开"的文件, 没有内核级的删除前回调, 所以由
**LD_PRELOAD 共享库** + **常驻守护进程** 协作完成:

1. 库劫持删除/重命名系统调用;
2. 按 inode 检查占用: 快照式扫描 `/proc/*/fd`、`maps`、`exe`、`cwd`
   (一次全量扫描构建"谁占用了什么"的哈希集合, 之后每次删除 O(1) 查询),
   `rm -rf` 批量删除不会逐文件全盘扫描;
3. 确认被占用 → 提示 (终端红字 / daemon 弹提示框) 并返回 `EBUSY` 阻止删除。
   daemon 不可用或无法弹窗时, 已判定的占用仍会阻止 (仅"无法判断"才放行)。

## 安装 (Debian/Ubuntu)

```bash
./install.sh      # 检测依赖 → 构建 → 安装 → 启动 daemon → 自启 → rm 别名
                  #   → 自动给文件管理器注入库并自动重启 (图形弹窗开箱即用)
./uninstall.sh    # 一键卸载 (含移除注入)
```

**权限要求(重要)**:

- 必须以**普通用户**运行, `sudo ./install.sh` / root 直接运行会被**拒绝**并提示
- 需要 root 权限的步骤(安装到 `/usr/local`、apt 安装依赖等)脚本会**自动使用
  `sudo` 并询问密码**

安装脚本会自动给检测到的常见文件管理器 (Nautilus / Thunar / Dolphin /
Nemo / Caja / PcManFM) 创建 `~/.local/share/applications/` 启动项覆盖:
在 `Exec=` 前加 `env LD_PRELOAD=...`, 并把 `DBusActivatable` 置为 `false`
(否则 D-Bus 激活会绕过 Exec=, 注入不生效)。然后**自动重启**运行中的
文件管理器(经 .desktop 重新拉起, 新进程即加载拦截库)——安装完图形弹窗
直接可用。不想自动重启: `SAFEUNLINK_NO_RESTART=1 ./install.sh`。

未检测到文件管理器或想手动注入时, 以 Nautilus 为例:

```bash
cp /usr/share/applications/org.gnome.Nautilus.desktop ~/.local/share/applications/
# 编辑副本, 做两处修改:
#   Exec=env LD_PRELOAD=/usr/local/lib/libsafeunlink.so /usr/bin/nautilus %U
#   DBusActivatable=false        ← 关键! 否则 D-Bus 激活绕过 Exec, 注入不生效
```

> 注意: 注入后必须**完全退出文件管理器再重新打开** (`nautilus -q` 后从
> 启动器打开), 旧进程不带库。验证是否生效:
> `grep libsafeunlink /proc/$(pgrep -x nautilus)/maps` 有输出即成功。

## 用法

```bash
bin/safe-rm important.txt     # 或已安装后直接 rm
safeunlinkd start|stop|status # 守护进程管理 (安装时已自动启动+自启)
```

全部行为是默认写死的, 只有一个紧急开关:

| 环境变量 | 作用 |
|---|---|
| `SAFEUNLINK_DISABLE=1` | 完全放行 (万一出问题时的逃生门) |

## 构建与测试

```bash
make          # 构建 build/libsafeunlink.so / build/safeunlinkd
make test     # 27 项测试
```

## 设计原则

- **只提示, 不允许删除**: 一旦确认文件被占用, 一律阻止 (`EBUSY`),
  不提供继续删除的选项
- **fail-open 仅针对"无法判断"**: 路径解析失败、/proc 不可读等异常放行,
  绝不阻塞正常文件操作; 但已判定占用时不受此影响
- **快照窗口**: 占用检查基于最多 2 秒前的快照, 刚打开的文件可能漏报
  (批量删除的性能取舍)
- **"其他程序"语义**: 删除者自身占用不误报; 硬链接按 inode 判断;
  符号链接按链接自身判断; `/proc` `/sys` `/run` 与设备节点内置豁免
- **去重**: `mv` 的 renameat2→renameat 回退链不会重复提示
- **回收站被阻止后的跟随删除**: 文件管理器会接着弹"要立刻删除吗?",
  确认后的 unlink 同样被阻止且不再二次提示 (全程只提示一次)
- **绕过**: setuid 程序、静态链接二进制不受 LD_PRELOAD 影响 (已知边界)

日志: `~/.local/state/safeunlink/safeunlinkd.log` (daemon 记录每次查询与弹窗结果)
