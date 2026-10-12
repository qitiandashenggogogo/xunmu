import Foundation

/// 面向用户的品牌名称。
///
/// 只管「显示给人看」的名字。可执行文件名、Bundle ID、数据目录、SwiftPM 包名与
/// 环境变量前缀仍保持 MacEverything / MACEVERYTHING，改展示名不会迁移已有索引。
public enum AppBrand {
    /// 菜单、窗口标题、文件名里用的中文名。
    public static let displayName = "寻目"
    /// 品牌介绍用的完整写法。
    public static let fullName = "寻目 · Xunmu"
}
