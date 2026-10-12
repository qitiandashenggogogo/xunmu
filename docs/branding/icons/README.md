# App 图标候选

状态（2026-10-12）：

- **A（文件夹＋放大镜，蓝青）已由用户选定。** `A-folder-search/A-folder-search.icns` 原样（逐字节相同）复制为 `Resources/AppIcon.icns`，作为稳定的发布资源；打包不依赖本目录。
- **B（光点＋轨迹，蓝紫）保留为候选记录**，不用于打包。
- 源码接入已完成：`Scripts/build-app.sh` 在构建前检查 `Resources/AppIcon.icns` 存在、非空且为 icns，签名前复制到 `Contents/Resources/AppIcon.icns`，并在 Info.plist 写 `CFBundleIconFile = AppIcon`。
- **2026-10-12 主控实际验收**：新包构建成功，Godox Dev 签名及 `codesign --verify --deep --strict` 通过；包内图标与发布资源逐字节一致，系统 `NSWorkspace.icon(forFile:)` 返回所选 A 图标，已查看渲染结果。启动冒烟退出 0，`indexed=63`、`reportMatches=20`、查询与选区恢复均通过。未做另一台 Mac 的 Finder/Dock 安装验收。
- 产品名已定为「寻目 · Xunmu」，图标里不放文字。

注意：重新运行生成器会覆盖本目录下的候选文件，但**不会**改动 `Resources/AppIcon.icns`。若以后要更新发布图标，需要显式重新复制并重新验收。

## 重新生成

```sh
# 在仓库根目录执行
swift Scripts/generate-icon-proposals.swift
```

所有图形都由 `Scripts/generate-icon-proposals.swift` 用 Swift CoreGraphics 矢量绘制，再通过 ImageIO 写成 PNG；`.icns` 由系统自带的 `/usr/bin/iconutil` 生成。没有使用 AI 图像生成、外部素材或其他项目的 logo。生成器每次运行都会覆盖本目录下的产物。

## 目录

| 路径 | 内容 |
|---|---|
| `A-folder-search/A-folder-search-{1024,512,256,128,64,32,16}.png` | A 方向，各尺寸单独绘制 |
| `A-folder-search/A-folder-search.icns` | A 的候选 icns（16–512@2x 共 10 张） |
| `B-orbit-search/B-orbit-search-{…}.png`、`B-orbit-search.icns` | B 方向，结构同上 |
| `icon-proposals-AB-board.png` | A/B 对照板：512 大图、256/128/64/32/16 原像素尺寸、浅/深背景、16px×6 与 32px×3 像素放大 |

## 两个方向

- **A · 文件夹＋放大镜（蓝青）**：青到蓝的渐变底板，浅色文件夹（后片带标签页，前片近白），海军蓝放大镜压在文件夹右下角，镜片为半透明浅青色。立体感来自文件夹和放大镜的投影、镜片高光弧，以及镜框内缘的亮线。含义直白：“在文件里找”。
- **B · 光点＋轨迹（蓝紫）**：蓝到紫的斜向渐变底板，一条由细到粗的彗尾轨迹顺时针绕行 270°，末端是发光点；中心另有一个被“找到”的白色光点。更抽象，偏“查找定位”的标志感。

## 尺寸策略

- 设计坐标为 1024；主体是 824×824 的超椭圆（n=5），四周留白给系统网格和投影。主体外四角完全透明，生成器会读回像素做核查。
- 每个尺寸都按自己的像素数**重新绘制**，不是从 1024 缩小。
- **≤32px 使用小尺寸版**：去掉底板投影、顶部柔光、内描边、物件投影、镜片高光和光晕，笔画加粗。
  - A：文件夹稍放大，镜框宽度从 44 加到 66，手柄宽度从 66 加到 92，镜片加深。
  - B：去掉淡轨道圈和光晕，轨迹最细处从 4 加到 16、最粗处从 64 加到 92，头部光点和中心光点放大，轨迹尾部保留少量不透明度。
