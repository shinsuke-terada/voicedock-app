// docs/SPEC.md が docs/PLAN.md の表の写しであることの検査（PLAN を直して SPEC を作り直し忘れたら落ちる。T-05）。
import TestSupport
import Testing

@Suite("SpecMatchesPlan")
struct SpecMatchesPlanTests {
    @Test("状態・遷移・復旧写像が PLAN と同じ", arguments: SpecEntity.allCases)
    func statesAndEdgesMatchPlan(_ entity: SpecEntity) throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.stateNames(entity) == plan.stateNames(entity))
        #expect(try spec.transitionEdges(entity) == plan.transitionEdges(entity))
        #expect(try spec.recoveryEdges(entity) == plan.recoveryEdges(entity))
    }

    @Test("エラーコードとログイベントが PLAN と同じ")
    func errorCodesAndEventsMatchPlan() throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.errorCodes() == plan.errorCodes())
        #expect(try spec.logEvents() == plan.logEvents())
    }

    @Test("ID の表が PLAN と同じ", arguments: SpecIDKind.allCases)
    func idsMatchPlan(_ kind: SpecIDKind) throws {
        let spec = try SpecDocument.load()
        let plan = try SpecDocument.plan()
        #expect(try spec.ids(kind) == plan.ids(kind))
        #expect(try spec.retiredIDs(kind) == plan.retiredIDs(kind))
    }

    @Test("ND の層が PLAN と同じ")
    func ndLayersMatchPlan() throws {
        #expect(try SpecDocument.load().ndLayers() == SpecDocument.plan().ndLayers())
    }
}
