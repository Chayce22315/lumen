import Foundation
import LumenFoundation
import LumenPersistence

/// Derives an entity's local `EntityState` from the last synchronized state and the local
/// changes recorded since then.
///
/// Field timestamps are exact: a field gets the timestamp of the local change that actually
/// modified it, found by diffing each pending change against the change before it. Fields a
/// local change did not touch keep their synchronized timestamps, so they can never overwrite
/// a newer remote edit.
public enum EntityStateBuilder {
    /// - Parameters:
    ///   - shadow: the last synchronized state (`.empty` for never-synchronized entities).
    ///   - previous: the snapshot immediately before the first pending change, if still in the log;
    ///     falls back to the shadow's snapshot.
    ///   - pending: change records from the first unsynchronized local change onwards, oldest first.
    ///     Remote-origin records among them (merges applied meanwhile) only advance the comparison
    ///     baseline; their fields are already part of `shadow`.
    public static func localState(shadow: EntityState, previous: JSONValue??, pending: [ChangeRecord]) -> EntityState {
        var state = shadow
        var prior: JSONValue? = previous ?? shadow.snapshot
        for change in pending {
            if change.origin == .remote {
                prior = change.operation == .delete ? nil : change.payload
                continue
            }
            switch change.operation {
            case .delete:
                state.tombstone = [state.tombstone, change.timestamp].compactMap { $0 }.max()
                prior = nil
            case .upsert:
                let current = change.payload?.objectValue ?? [:]
                let before = prior?.objectValue
                let keys = Set(current.keys).union(before.map { Array($0.keys) } ?? [])
                for key in keys {
                    let newValue = current[key]
                    if before == nil || before?[key] != newValue {
                        state.fields[key] = FieldState(value: newValue, timestamp: change.timestamp)
                    }
                }
                prior = change.payload
            }
        }
        return state
    }

    /// Fields both sides changed since `shadow` to different values. The later write is `chosen`.
    public static func conflicts(shadow: EntityState, local: EntityState, remote: EntityState) -> [FieldConflict] {
        var conflicts: [FieldConflict] = []
        for key in Set(local.fields.keys).intersection(remote.fields.keys).sorted() {
            guard let l = local.fields[key], let r = remote.fields[key], l.value != r.value else { continue }
            let base = shadow.fields[key]?.timestamp ?? .zero
            guard l.timestamp > base, r.timestamp > base else { continue }
            conflicts.append(FieldConflict(field: key, localValue: l.value, remoteValue: r.value, chosen: r.timestamp > l.timestamp ? .remote : .local))
        }
        // Deletion racing an edit.
        let localDeleted = local.isDeleted && !shadow.isDeleted
        let remoteDeleted = remote.isDeleted && !shadow.isDeleted
        if localDeleted != remoteDeleted, local.latestTimestamp > shadow.latestTimestamp, remote.latestTimestamp > shadow.latestTimestamp {
            let merged = local.merged(with: remote)
            let localWon = merged.isDeleted == localDeleted
            conflicts.append(FieldConflict(
                field: "*",
                localValue: local.snapshot,
                remoteValue: remote.snapshot,
                chosen: localWon ? .local : .remote
            ))
        }
        return conflicts
    }
}
