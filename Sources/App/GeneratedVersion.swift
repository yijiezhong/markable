// 由 scripts/bump-version.sh 生成，勿手改。
// 每次编译（scripts/build.sh）或打包（scripts/make-app-bundle.sh）自动递增后覆盖。
enum AppVersion {
    /// 版本号（x.y.z，每位 0–9，满 9 进位）
    static let short = "1.5.8"
    /// 构建号（当前时间，精确到秒：YYYYMMDDhhmmss）
    static let build = "20261125103858"
    /// 「关于」窗口显示的一行
    static var display: String { "v\(short) (\(build))" }
}
