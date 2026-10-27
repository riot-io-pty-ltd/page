import Foundation
import WidgetKit
import PageWidgetSupport

/// Keeps the widgets' snapshot file current and asks WidgetKit to reload them.
/// The decisions about when are `WidgetPublishGate`'s (pure); this class holds
/// the latest snapshot, the timers and the file. Main thread in, file work on
/// its own queue. With no app group (a build that was not signed with a team)
/// it does nothing at all, and never touches a group container.
final class WidgetPublisher {
    private var gate = WidgetPublishGate()
    private var latest: WidgetSnapshot?
    private var recheck: DispatchWorkItem?
    private var heartbeat: Timer?
    private let queue: DispatchQueue?
    private let directory: () -> URL?
    private let reload: () -> Void
    private let clock: () -> Date
    private var loggedNoGroup = false
    /// Writes and reloads, for tests to read.
    private(set) var writes = 0
    private(set) var reloads = 0

    init(directory: @escaping () -> URL?, reload: @escaping () -> Void, clock: @escaping () -> Date = Date.init,
         queue: DispatchQueue? = DispatchQueue(label: "ClaudePowerMode.widgets", qos: .utility)) {
        self.directory = directory
        self.reload = reload
        self.clock = clock
        self.queue = queue
    }

    /// The real one: the app group from this bundle's Info.plist, WidgetKit's reload for both widgets.
    static func live() -> WidgetPublisher {
        WidgetPublisher(
            directory: { WidgetSnapshotStore.containerURL() },
            reload: {
                for kind in [PageWidgetConstants.statusKind, PageWidgetConstants.usageKind] {
                    WidgetCenter.shared.reloadTimelines(ofKind: kind)
                }
            })
    }

    /// A newer snapshot. Writes and reloads only as the gate allows; a change
    /// the gate holds back is offered again when it would be allowed.
    func offer(_ snapshot: WidgetSnapshot, force: Bool = false) {
        latest = snapshot
        let now = clock()
        let action = gate.offer(fingerprint: snapshot.fingerprint(), urgent: snapshot.urgentFingerprint(), now: now, force: force)
        if action.write || action.reload { perform(action, snapshot: snapshot, now: now) }
        if let wait = action.recheckIn { scheduleRecheck(after: wait) }
    }

    /// Wake from sleep: write and reload now.
    func refreshNow() {
        guard let s = latest else { return }
        offer(s, force: true)
    }

    /// Quit: leave the last numbers with a note that Page is not running.
    func publishQuit() {
        guard var s = latest else { return }
        s.running = false
        s.writtenAt = clock()
        // Behind any write already queued, so the quit note is the last word.
        let work = { [self] in
            guard let dir = directory() else { return }
            if WidgetSnapshotStore.write(s, to: dir) { writes += 1 }
            reload()
            reloads += 1
        }
        if let queue { queue.sync(execute: work) } else { work() }
    }

    /// Re-offers the latest snapshot every minute, so the heartbeat write (and
    /// a held-back change) happens without a new model.
    func start() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, var s = self.latest else { return }
            s.writtenAt = self.clock()
            self.offer(s)
        }
    }

    // MARK: private

    private func perform(_ action: WidgetPublishGate.Action, snapshot: WidgetSnapshot, now: Date) {
        var s = snapshot
        s.writtenAt = now
        let work = { [self] in
            guard let dir = directory() else {
                if !loggedNoGroup {
                    loggedNoGroup = true
                    Logger.shared.log("Widgets: this build has no app group, so the widgets stay empty (build.sh signs one in)")
                }
                return
            }
            if action.write, WidgetSnapshotStore.write(s, to: dir) { writes += 1 }
            if action.reload { reload(); reloads += 1 }
        }
        if let queue { queue.async(execute: work) } else { work() }
    }

    private func scheduleRecheck(after wait: TimeInterval) {
        recheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let s = self.latest else { return }
            self.offer(s)
        }
        recheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, wait), execute: item)
    }
}
