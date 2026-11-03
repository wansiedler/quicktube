import CoreAudio
import Foundation

/// An audio input device as CoreAudio names it.
public struct AudioInputDevice: Sendable, Equatable {
    public let id: AudioDeviceID
    /// Stable across launches; what `SCStreamConfiguration.microphoneCaptureDeviceID` takes.
    public let uid: String?
    public let name: String?

    public init(id: AudioDeviceID, uid: String?, name: String?) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

/// Reports every change of the system default input device (`kAudioHardwarePropertyDefaultInputDevice`)
/// until it is released. The callback runs on a private serial queue.
public final class DefaultInputObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "QuickTube.DefaultInputObserver")
    private let listener: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var registered = false

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public init(onChange: @escaping @Sendable (AudioInputDevice) -> Void) {
        listener = { @Sendable _, _ in
            guard let device = DefaultInputObserver.currentDefaultInput() else { return }
            onChange(device)
        }
        var address = Self.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        registered = status == noErr
        if !registered { NSLog("QuickTube: cannot observe the default input device (\(status))") }
    }

    deinit { stop() }

    /// Removes the listener; later changes are not reported.
    public func stop() {
        let wasRegistered = lock.withLock {
            defer { registered = false }
            return registered
        }
        guard wasRegistered else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
    }

    /// The default input device now, or nil when there is none.
    public static func currentDefaultInput() -> AudioInputDevice? {
        var address = defaultInputAddress
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return AudioInputDevice(
            id: id, uid: string(kAudioDevicePropertyDeviceUID, of: id),
            name: string(kAudioObjectPropertyName, of: id))
    }

    /// A CFString property of `device` (its UID, its name).
    public static func string(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
