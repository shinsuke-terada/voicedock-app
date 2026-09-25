// SPEC 同期の拡張（issue #18。PLAN F-68）: S8 の理由語の列と S10〜S13・S20〜S23 が PLAN の表の写しで、空でなく、読み方が固定されていること。
// 実装との照合は各モジュールのテスト（SpecSyncContract・SpecSyncWhisperArgs・NoteVerifier・SpecSyncTickOrder・IconState・
// PanelScreen・Onboarding・UIState）と PanelStructure・NoteRuleCoverage が行う。
import TestSupport
import Testing

@Suite("SpecExtendedSections")
struct SpecExtendedSectionsTests {
    @Test("拡張した節が PLAN と同じ")
    func extendedSectionsMatchPlan() throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.reasonWords() == plan.reasonWords())
        #expect(try spec.namePatterns() == plan.namePatterns())
        #expect(try spec.whisperArgv() == plan.whisperArgv())
        for kind in SpecNoteKind.allCases {
            #expect(try spec.noteRules(kind) == plan.noteRules(kind))
        }
        #expect(try spec.tickStages() == plan.tickStages())
        #expect(try spec.panelSections() == plan.panelSections())
        #expect(try spec.iconRows() == plan.iconRows())
        #expect(try spec.onboardingSteps() == plan.onboardingSteps())
        #expect(try spec.uiStateKeys() == plan.uiStateKeys())
    }

    @Test("拡張した節が空でなく、名前が重ならない")
    func extendedSectionsAreNotEmpty() throws {
        let spec = try SpecDocument.load()
        func unique(_ values: [String], _ label: String) {
            #expect(!values.isEmpty, "\(label) が空")
            #expect(Set(values).count == values.count, "\(label) が重なる: \(values)")
        }
        unique(try spec.reasonWords(), "S8 の理由語")
        unique(Array(try spec.namePatterns().keys), "S10")
        unique(try spec.whisperArgv(), "S11")  // 同じ語が 2 度出ない（パスは <slug> などで互いに違う）
        unique(try SpecNoteKind.allCases.flatMap { try spec.noteRules($0) }, "S12")
        unique(try spec.tickStages().map(\.name), "S13")
        unique(try spec.panelSections().map(\.title), "S20")
        unique(try spec.iconRows().map(\.symbol), "S21")
        unique(try spec.onboardingSteps().map(\.step), "S22")
        unique(try spec.uiStateKeys().map(\.key), "S23")
    }

    @Test("表の中の \\| を | に戻し、— の欄を「無い」と読む")
    func readsEscapedPipesAndDashes() throws {
        let text = """
            ## S10. 正規表現

            | 定数 | 正規表現 |
            |---|---|
            | `A.p` | `^(a\\|b)$` |

            ## S12. RN / DN

            | # | Raw（RN。voicedock R-n） | Daily（DN。voicedock W-n） |
            |---|---|---|
            | 1 | x | 同左 |
            | 2 | — | y |

            ## S20. パネル

            | # | 節 | 主画面 | 画面 |
            |---|---|---|---|
            | 1 | 状態 | カード | — |
            | 2 | 一般 | —（別の所） | `settings` |
            """
        let spec = SpecDocument(text: text)
        #expect(try spec.namePatterns() == ["A.p": "^(a|b)$"])
        #expect(try spec.noteRules(.raw) == ["RN-1"])
        #expect(try spec.noteRules(.daily) == ["DN-1", "DN-2"])
        let sections = try spec.panelSections()
        #expect(sections.map(\.number) == [1, 2])
        #expect(sections.map(\.title) == ["状態", "一般"])
        #expect(sections.map(\.onMain) == [true, false])
        #expect(sections.map(\.screen) == [nil, "settings"])
    }

    @Test("理由語は理由語の列のバッククォートの語だけを出現順に読む（表の外と他の列は読まない）")
    func readsReasonWordsFromTheColumn() throws {
        let text = """
            ## S8. RV

            | # | 検証 | 理由語 | 要求の扱い |
            |---|---|---|---|
            | RV-00 | `bin` の置き場所 | （終了コード 3） | 触らない |
            | RV-01 | conf | `lock1`（false）/ `conf_invalid` | 触らない |
            | RV-06 | 形 | `device_absent` / `lock1` | 拒否 |

            旧 reaper の理由語 `realpath_failed` は出ない。
            """
        #expect(try SpecDocument(text: text).reasonWords() == ["lock1", "conf_invalid", "device_absent"])
        #expect(try SpecDocument(text: "## S8. RV\n").reasonWords() == [])
    }
}
