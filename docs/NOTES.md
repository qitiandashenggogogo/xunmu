# 维护记录

## 2026-10-09：目录校验查询的隐藏全卷扫描

问题：10 万条合成索引、4000 个目录批次入库约 52 秒。进程采样显示大部分 CPU 时间停在目录缺失条目 SELECT。
原因：`ORDER BY relative_path` 让 SQLite 选择 `(volume_id, relative_path)`，只按卷过滤，反复扫整卷，而非 `(volume_id, parent_path)`。
解决：缺失条目无需排序，移除 ORDER BY。相同规模入库降至约 2.9 秒。改变 SQL 时必须同时检查计划与真实基准，不能只检查有无索引。

## 2026-10-09：Darwin 批量枚举和真实事件路径

`getattrlistbulk` 返回条目数，不是缓冲字节数；名称长度包含末尾 NUL，属性按 4 字节对齐，vnode 类型是 VREG/VDIR/VLNK，不是 readdir 的 DT_*。
批量结果需要用真实目录验证，不能靠 fallback 跑通来掩盖解码错误。空目录成功也必须释放 C 缓冲。
FSEvents 根路径使用 POSIX realpath；Foundation 的 `/var` URL 形式不能替代设备相对流需要的 `/private/var` 实路径。真实创建/改名/离线修改重播测试已覆盖。

## 2026-10-09：iCloud Documents 会破坏包签名复验

生成的 .app 即使签名时清掉 FinderInfo，File Provider 后续仍可能重新附加它，严格 codesign 复验失败。
解决：应用实体构建在本机 Library/Caches；项目 dist 下只保留链接。不修改系统策略、不移除用户文件 quarantine。

## 2026-10-10：云端占位文件也会阻塞编译

清理本机空间后，iCloud Documents 中的 Swift 模块缓存带 dataless 标志，编译器长时间等待 mmap；源码恢复时又改变时间戳，触发「input file was modified during the build」。源码 Git 差异没有对应修改。
解决：打包和测试的编译缓存默认放在 Library/Caches，编译前读取项目输入。重新构建、严格验签与 286 项回归通过。缓存可删除，但重新试用前需运行构建脚本恢复 .app。

## 2026-10-10：表格右键必须接入视图事件

真实鼠标验收发现右键不弹菜单。`tableView(_:rightMouseDown:)` 不是 NSTableViewDelegate 方法，放在控制器里不会收到事件。
解决：ResultsTableView 覆写 `rightMouseDown(with:)` 并转交控制器；回归用真实 NSEvent 验证视图分发，不能只直接调用控制器的菜单生成函数。
