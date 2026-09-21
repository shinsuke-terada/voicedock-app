// テストのタグ（PLAN §10.1。swift test はタグで絞れないので、意味を示すためだけに付ける）。
import Testing

extension Tag {
    /// hdiutil で FAT32 イメージを作るテスト。`TestEnvironment.diskTests` と組で使う。
    @Tag public static var diskImage: Self
    /// 本物の whisper-cli / llama-server とモデルが要るテスト。
    @Tag public static var realTools: Self
    /// 時間のかかるテスト。
    @Tag public static var slow: Self
}
