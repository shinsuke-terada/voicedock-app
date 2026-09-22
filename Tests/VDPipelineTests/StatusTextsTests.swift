// StatusTexts（未処理の 1 行・GiB・ガードの理由の語）のテスト（T-30 §5.4）。
import Testing
import VDPipeline

@Suite("StatusTexts")
struct StatusTextsTests {
    @Test("0 件は『未処理なし』")
    func backlogNone() {
        #expect(StatusTexts.backlogLine(count: 0, seconds: 0, unknownDuration: 0) == "未処理なし")
    }

    @Test("時間は小数 1 桁")
    func backlogHoursOneDecimal() {
        #expect(StatusTexts.backlogLine(count: 6, seconds: 11_520, unknownDuration: 0) == "未処理 3.2 時間ぶん（6 件）")
    }

    @Test("長さ不明の件数を併記する")
    func backlogUnknownDuration() {
        #expect(
            StatusTexts.backlogLine(count: 6, seconds: 11_520, unknownDuration: 1)
                == "未処理 3.2 時間ぶん（6 件）、うち 1 件は長さ不明")
    }

    @Test("全部長さ不明なら 0.0 時間")
    func backlogZeroSecondsButParts() {
        #expect(
            StatusTexts.backlogLine(count: 2, seconds: 0, unknownDuration: 2)
                == "未処理 0.0 時間ぶん（2 件）、うち 2 件は長さ不明")
    }

    @Test("GiB は小数 1 桁")
    func gibOneDecimal() {
        #expect(StatusTexts.gib(4_509_715_660) == "4.2 GiB")
    }

    @Test("0 と負の値は 0.0 GiB")
    func gibZeroAndNegative() {
        #expect(StatusTexts.gib(0) == "0.0 GiB")
        #expect(StatusTexts.gib(-1) == "0.0 GiB")
    }

    @Test("ガードの理由の 11 語")
    func pauseWords() {
        let expected: [(PauseReason, String)] = [
            (.diskSpaceLow, "空き容量不足"),
            (.whisperMissing, "whisper-cli がありません"),
            (.modelMissing, "Whisper モデルがありません"),
            (.vadModelMissing, "VAD モデルがありません"),
            (.vaultNotConfigured, "Vault が未設定"),
            (.vaultUnavailable, "Vault が使えません"),
            (.llmNotSelected, "LLM が未選択"),
            (.llmModelMissing, "LLM モデルがありません"),
            (.llmInsufficientMemory, "メモリ不足"),
            (.llamaServerMissing, "llama-server がありません"),
            (.license, "ライセンス"),
        ]
        #expect(PauseReason.allCases.count == 11)
        #expect(expected.map(\.0) == PauseReason.allCases)
        for (reason, word) in expected {
            #expect(StatusTexts.pauseWord(reason) == word)
        }
    }
}
