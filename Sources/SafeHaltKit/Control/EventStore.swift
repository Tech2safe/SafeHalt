// Sources/SafeHaltKit/Control/EventStore.swift
import Foundation

/// 近期事件落盘，让面板在重启后仍能看到断电/关机记录。读写失败一律静默，绝不影响保护循环。
public struct EventStore: Sendable {
    public let path: String
    public init(path: String) { self.path = path }

    public func load() -> [EngineEvent] {
        guard let data = FileManager.default.contents(atPath: path),
              let events = try? JSONDecoder().decode([EngineEvent].self, from: data) else { return [] }
        return events
    }

    public func save(_ events: [EngineEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
