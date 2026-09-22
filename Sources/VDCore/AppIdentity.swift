// アプリの識別子（PLAN §3.1）。値は identity.env と同じ（AppIdentityTests が照合する）。本番コードはここからだけ読む（環境変数を読まない。PT-18）。
public enum AppIdentity {
    /// identity.env の BUNDLE_ID（T-01 が P0 の章 14 から写した値をそのまま書く）
    public static let bundleID = "io.github.shinsuke-terada.VoiceDock"
    /// identity.env の TEAM_ID（10 文字）
    public static let teamID = "ZCWP35H248"
    /// reaper の署名の識別子（PLAN §3.1「<BUNDLE_ID>.reaper」）
    public static var reaperIdentifier: String { bundleID + ".reaper" }
}
