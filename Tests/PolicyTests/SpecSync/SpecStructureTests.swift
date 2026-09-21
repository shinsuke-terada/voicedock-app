// docs/SPEC.md が読め、各節が空でなく、ID が重ならないことの検査（PLAN §10.3・CR-18。T-05）。
import TestSupport
import Testing

@Suite("SpecStructure")
struct SpecStructureTests {
    @Test("docs/SPEC.md が在る（無ければ skip ではなく fail）")
    func specExists() throws {
        _ = try SpecDocument.load()
    }

    @Test("状態・遷移・復旧写像が Part と Session の両方で空でない", arguments: SpecEntity.allCases)
    func statesAndEdgesAreNotEmpty(_ entity: SpecEntity) throws {
        let spec = try SpecDocument.load()
        #expect(!(try spec.stateNames(entity)).isEmpty)
        #expect(!(try spec.transitionEdges(entity)).isEmpty)
        #expect(!(try spec.recoveryEdges(entity)).isEmpty)
    }

    @Test("エラーコードとログイベントが空でない")
    func errorCodesAndEventsAreNotEmpty() throws {
        let spec = try SpecDocument.load()
        #expect(!(try spec.errorCodes()).isEmpty)
        #expect(!(try spec.logEvents()).isEmpty)
    }

    @Test("ID の表が空でなく、ID が重ならない", arguments: SpecIDKind.allCases)
    func idsAreUniqueAndNotEmpty(_ kind: SpecIDKind) throws {
        let ids = try SpecDocument.load().ids(kind)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "重複: \(ids)")
    }

    @Test("廃止した ID を生きた ID として再利用しない", arguments: SpecIDKind.allCases)
    func retiredIDsAreNotReused(_ kind: SpecIDKind) throws {
        let spec = try SpecDocument.load()
        #expect(Set(try spec.ids(kind)).isDisjoint(with: try spec.retiredIDs(kind)))
    }

    @Test("状態・エラーコード・イベントの名前が重ならない")
    func namesAreUnique() throws {
        let spec = try SpecDocument.load()
        for entity in SpecEntity.allCases {
            let names = try spec.stateNames(entity)
            #expect(Set(names).count == names.count)
        }
        let codes = try spec.errorCodes().map(\.code)
        #expect(Set(codes).count == codes.count)
        let events = try spec.logEvents()
        #expect(Set(events).count == events.count)
    }

    @Test("遷移と復旧写像の辺は状態の表に在る状態だけを使う", arguments: SpecEntity.allCases)
    func edgesUseKnownStates(_ entity: SpecEntity) throws {
        let spec = try SpecDocument.load()
        let states = Set(try spec.stateNames(entity))
        for edge in try spec.transitionEdges(entity) + spec.recoveryEdges(entity) {
            #expect(states.contains(edge.from) && states.contains(edge.to), "\(entity.rawValue) の \(edge)")
        }
    }

    @Test("エラーコードの再試行の列は 4 つの値のどれか")
    func retryColumnValues() throws {
        let allowed: Set<String> = ["none", "nextPoll", "nextConnect", "attempts"]
        for row in try SpecDocument.load().errorCodes() {
            #expect(allowed.contains(row.retry), "\(row.code): \(row.retry)")
        }
    }

    @Test("ND の層の列は A・R1・R2・R3 の組み合わせ")
    func ndLayersAreKnown() throws {
        let spec = try SpecDocument.load()
        let layers = try spec.ndLayers()
        for id in try spec.ids(.nd) {
            let value = try #require(layers[id], "\(id) の層が無い")
            #expect(!value.isEmpty && Set(value).isSubset(of: ["A", "R1", "R2", "R3"]), "\(id): \(value)")
        }
    }
}
