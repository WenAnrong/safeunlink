# safeunlink — 删除前检查"文件是否被占用"

删除文件前, 先检查是否有**其他进程**仍在使用该文件 (fd / mmap / cwd / exe)。
被占用时:

- **终端** (`rm` 等): 红色文字提示占用者 + 询问 (`y` 继续 / 其他取消)
- **图形界面** (文件管理器等, 无终端): 弹 zenity 图形框 ("仍然删除" / "取消")

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
3. 被占用时: 有终端 → 红色提示 + 询问; 无终端 → 经 daemon 弹 zenity 图形框;
   daemon 不可用或无法弹窗 → 提示后放行 (fail-open)。

## 安装 (Debian/Ubuntu)

```bash
./install.sh      # 检测依赖 → 构建 → 安装 → 启动 daemon → 自启 → rm 别名
./uninstall.sh    # 一键卸载
```

安装后开新终端即可使用 (终端直接 `rm`; 图形文件管理器需按下方"文件管理器接入"
注入库)。

## 用法

```bash
bin/safe-rm important.txt     # 或已安装后直接 rm
safeunlinkd start|stop|status # 守护进程管理 (安装时已自动启动+自启)
```

全部行为是默认写死的, 只有一个紧急开关和脚本预答:

| 环境变量 | 作用 |
|---|---|
| `SAFEUNLINK_DISABLE=1` | 完全放行 (万一出问题时的逃生门) |
| `SAFEUNLINK_ANSWER=y\|n` | 无终端时预置回答 (脚本场景) |

## 文件管理器接入

图形弹窗需要文件管理器进程加载本库。给文件管理器注入 (以 Nautilus 为例):

```bash
cp /usr/share/applications/org.gnome.Nautilus.desktop ~/.local/share/applications/
# 编辑副本, Exec= 改为:
#   Exec=env LD_PRELOAD=/usr/local/lib/libsafeunlink.so /usr/bin/nautilus %U
```

Thunar / Dolphin 同理。之后在文件管理器里删除/移入回收站被占用的文件时,
会弹出 zenity 询问框。

## 构建与测试

```bash
make          # 构建 build/libsafeunlink.so / build/safeunlinkd
make test     # 23 项测试
```

## 设计原则

- **fail-open**: 任何异常 (路径解析失败、/proc 不可读、daemon 挂掉、
  弹窗失败) 一律放行, 绝不阻塞正常文件操作
- **快照窗口**: 占用检查基于最多 2 秒前的快照, 刚打开的文件可能漏报
  (批量删除的性能取舍)
- **"其他程序"语义**: 删除者自身占用不误报; 硬链接按 inode 判断;
  符号链接按链接自身判断; `/proc` `/sys` `/run` 与设备节点内置豁免
- **去重**: `mv` 的 renameat2→renameat 回退链不会重复提示
- **绕过**: setuid 程序、静态链接二进制不受 LD_PRELOAD 影响 (已知边界)

日志: `~/.local/state/safeunlink/safeunlinkd.log` (daemon 记录每次查询与弹窗结果)
