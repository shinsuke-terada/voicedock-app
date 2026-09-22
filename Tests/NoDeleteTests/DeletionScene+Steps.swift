// DeletionScene から削除の段の依存を作る（T-38）。DeletionDependencies は internal なので test ターゲットごとに置く。
import TestSupport
import VDContract
import VDCore

@testable import VDPipeline

extension DeletionScene {
    /// 今の設定で 1 tick 分の依存を作る（設定を変えたら作り直す）。warn は config_warning rule=store を出す
    func deletionDependencies(
        ingest: any IngestPort, pended: PendedPartkeys = PendedPartkeys(),
        locks: LockEvaluator? = nil, opener: (any VolumeOpener)? = nil
    ) -> DeletionDependencies {
        let log = self.log
        return DeletionDependencies(
            layout: layout, store: store, config: config, zone: zone, ingest: ingest, locks: locks ?? self.locks,
            volumeOpener: opener ?? self.opener, clock: clock, log: log, pended: pended,
            warn: { error in
                log.warning(.configWarning, [(.rule, "store"), (.message, .string(String(describing: error)))])
            })
    }
}
