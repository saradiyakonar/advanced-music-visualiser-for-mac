import Foundation

public protocol KeyValueStore: AnyObject {
    func double(forKey key: String) -> Double?
    func set(_ value: Double, forKey key: String)
    func remove(forKey key: String)
}

extension UserDefaults: KeyValueStore {
    public func double(forKey key: String) -> Double? {
        object(forKey: key) == nil ? nil : (double(forKey: key) as Double)
    }
    // set(_: Double, forKey:) is UserDefaults' own method.
    public func remove(forKey key: String) {
        removeObject(forKey: key)
    }
}

public final class InMemoryStore: KeyValueStore {
    private var values: [String: Double] = [:]
    public init() {}
    public func double(forKey key: String) -> Double? { values[key] }
    public func set(_ value: Double, forKey key: String) { values[key] = value }
    public func remove(forKey key: String) { values[key] = nil }
}

/// Extra visual delay per output device, on top of the device's reported latency.
/// Bluetooth devices tend to under-report, so they start with a correction.
public final class SyncOffsetStore {
    public static let bluetoothDefault = 0.12
    public static let step = 0.02
    public static let range = -0.3...0.6

    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    public func offset(forDeviceUID uid: String, isBluetooth: Bool) -> Double {
        store.double(forKey: key(uid)) ?? (isBluetooth ? Self.bluetoothDefault : 0)
    }

    public func nudge(deviceUID uid: String, isBluetooth: Bool, by delta: Double) {
        let next = offset(forDeviceUID: uid, isBluetooth: isBluetooth) + delta
        let clamped = min(max(next, Self.range.lowerBound), Self.range.upperBound)
        store.set((clamped * 1000).rounded() / 1000, forKey: key(uid))
    }

    public func reset(deviceUID uid: String) {
        store.remove(forKey: key(uid))
    }

    private func key(_ uid: String) -> String { "sync.offset.\(uid)" }
}
