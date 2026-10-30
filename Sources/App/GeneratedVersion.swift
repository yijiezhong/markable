// 由 scripts/bump-version.sh 生成，勿手改。
// 每次编译（scripts/build.sh）或打包（scripts/make-app-bundle.sh）自动递增后覆盖。
enum AppVersion {
    /// 版本号（x.y.z，每位 0–9，满 9 进位）
    static let short = "1.5.4"
    /// 构建号（递增时间）
    static let build = "202610301101"
    /// 「关于」窗口显示的一行
    static var display: String { "v\(short) (\(build))" }
}
