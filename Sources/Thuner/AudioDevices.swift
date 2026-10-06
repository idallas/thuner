import AppKit
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across reboots and replugging; this is what gets saved in settings.
    let uid: String
    let name: String
    let inputChannels: Int
}

enum AudioDevices {
    /// Inputs for the picker: "System Audio" (what this Mac is playing) first, then the real devices.
    static func inputDevices() -> [AudioInputDevice] {
        [AudioInputDevice(id: 0, uid: SystemAudioTap.uid, name: SystemAudioTap.name, inputChannels: 2)] + hardwareInputDevices()
    }

    static func hardwareInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            // Core Audio's own transient aggregate (it appears while some apps are using audio), and ThUNER's own
            // system-audio device: never inputs anyone means to pick.
            if name.hasPrefix("CADefaultDeviceAggregate") || uid.hasPrefix("com.idallas.thuner.tap.") { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, inputChannels: channels)
        }
    }

    static func device(uid: String) -> AudioInputDevice? {
        hardwareInputDevices().first { $0.uid == uid }
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return hardwareInputDevices().first { $0.id == id }
    }

    /// The processes currently sending audio to an output (macOS 14.2+ Core Audio process objects), not
    /// counting ThUNER. Nothing is listened to; Core Audio just reports who's doing output.
    static func processesPlayingAudio() -> Set<pid_t> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var pids = Set<pid_t>()
        for object in objects {
            var property = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &valueSize, &running) == noErr, running != 0 else { continue }
            property.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            valueSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &property, 0, nil, &valueSize, &pid) == noErr, pid != me { pids.insert(pid) }
        }
        return pids
    }

    /// An app, as far as system audio is concerned: remembered by bundle ID.
    struct AudioApp: Codable, Hashable, Identifiable, Sendable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    /// Every process Core Audio knows about (has made an audio connection), with its pid and bundle ID.
    static func audioProcesses() -> [(object: AudioObjectID, pid: pid_t, bundleID: String?)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.map { object in
            var property = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var valueSize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(object, &property, 0, nil, &valueSize, &pid)
            property.mSelector = kAudioProcessPropertyBundleID
            var bundle: Unmanaged<CFString>?
            valueSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleID = AudioObjectGetPropertyData(object, &property, 0, nil, &valueSize, &bundle) == noErr
                ? bundle?.takeRetainedValue() as String? : nil
            return (object, pid, bundleID)
        }
    }

    /// The app a process belongs to: itself if it's an app, or the app that started it (browsers play sound
    /// from helper processes). Nil for system services.
    static func owningApp(of pid: pid_t) -> AudioApp? {
        var current = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current), let bundleID = app.bundleIdentifier,
               app.activationPolicy != .prohibited {
                return AudioApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// The Core Audio process objects belonging to any of these apps: matching bundle ID, a helper whose
    /// bundle ID starts with the app's, or a process the app started.
    static func processObjects(for bundleIDs: Set<String>) -> [AudioObjectID] {
        guard !bundleIDs.isEmpty else { return [] }
        return audioProcesses().filter { process in
            if let id = process.bundleID, bundleIDs.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return true }
            if let owner = owningApp(of: process.pid) { return bundleIDs.contains(owner.bundleID) }
            return false
        }.map(\.object)
    }

    /// Calls `handler` on the main queue when processes start or stop using audio.
    static func observeAudioProcesses(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Calls `handler` on the main queue whenever devices are added or removed.
    static func observeDeviceListChanges(_ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
