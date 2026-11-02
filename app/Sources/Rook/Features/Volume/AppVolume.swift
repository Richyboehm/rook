import AppKit
import AudioToolbox
import CoreAudio

// Lautstärke pro App wie unter Windows. macOS kennt nur eine Lautstärke für alles; Rook
// zapft deshalb den Ton einer App ab (Core-Audio-Tap), schaltet das Original stumm und gibt
// den Ton leiser wieder aus. Steht eine App auf 100 %, läuft für sie nichts davon.
// Braucht die Erlaubnis „Audio-Aufnahme“.

@MainActor
final class AppVolume: ObservableObject {
    struct Source: Identifiable, Equatable {
        let id: String // Bundle-ID der App
        let name: String
        /// Für das Symbol; geladen wird es erst, wenn die Liste zu sehen ist.
        let bundleURL: URL?
        var processes: [AudioObjectID]
        var isPlaying: Bool
    }

    /// Apps, die gerade mit Core Audio verbunden sind; spielende zuerst.
    @Published private(set) var sources: [Source] = []
    @Published private(set) var volumes: [String: Float] = UserDefaults.standard.dictionary(forKey: "appVolumes") as? [String: Float] ?? [:]
    @Published private(set) var problem: String?

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            if enabled { start() } else { stop() }
        }
    }

    private var taps: [String: ProcessTap] = [:]
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var playingListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    /// Lautstärke vor dem Stummschalten, um sie wiederherzustellen.
    private var beforeMute: [String: Float] = [:]

    func volume(of id: String) -> Float { volumes[id] ?? 1 }

    func toggleMute(_ id: String) {
        if volume(of: id) > 0 {
            beforeMute[id] = volume(of: id)
            setVolume(0, for: id)
        } else {
            setVolume(beforeMute[id] ?? 1, for: id)
        }
    }

    func setVolume(_ value: Float, for id: String) {
        let value = min(max(value, 0), 1)
        volumes[id] = value >= 0.995 ? nil : value
        UserDefaults.standard.set(volumes, forKey: "appVolumes")
        if let tap = taps[id], value < 0.995 {
            tap.gain = value
        } else {
            applyTaps()
        }
    }

    // MARK: Start und Stopp

    private func start() {
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refresh()
        }
        // Neue Kopfhörer oder Lautsprecher: alle Abzweigungen auf das neue Gerät umbauen.
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.rebuildTaps()
        }
        refresh()
        Log.write("Lautstärke – Bereit")
    }

    private func stop() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()
        removePlayingListeners()
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
        sources = []
        problem = nil
        Log.write("Lautstärke – Ausgeschaltet")
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ action: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { action() } }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    // MARK: Apps finden

    /// Liest alle Prozesse mit Ton und fasst Hilfsprozesse (z. B. von Browsern) zu ihrer App zusammen.
    private func refresh() {
        guard enabled else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var grouped: [String: Source] = [:]
        for object in CoreAudio.processObjects() {
            guard let pid = CoreAudio.pid(of: object), pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: Responsibility.app(for: pid)),
                  app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, app.processIdentifier != ownPID else { continue }
            let playing = CoreAudio.isRunningOutput(object)
            if var source = grouped[id] {
                source.processes.append(object)
                source.isPlaying = source.isPlaying || playing
                grouped[id] = source
            } else {
                grouped[id] = Source(id: id, name: app.localizedName ?? id, bundleURL: app.bundleURL,
                                     processes: [object], isPlaying: playing)
            }
        }
        let sorted = grouped.values.sorted {
            $0.isPlaying != $1.isPlaying ? $0.isPlaying : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if sorted != sources { sources = sorted }
        watchPlaying()
        applyTaps()
    }

    /// Meldet, wenn eine App anfängt oder aufhört zu spielen, damit die Liste sortiert bleibt.
    private func watchPlaying() {
        let objects = Set(sources.flatMap(\.processes))
        guard objects != Set(playingListeners.keys) else { return }
        removePlayingListeners()
        for object in objects {
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                playingListeners[object] = block
            }
        }
    }

    private func removePlayingListeners() {
        for (object, block) in playingListeners {
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        playingListeners.removeAll()
    }

    // MARK: Abzweigungen

    /// Baut für jede leiser gestellte App eine Abzweigung, entfernt überflüssige und passt
    /// bestehende an neue Hilfsprozesse an.
    private func applyTaps() {
        guard enabled else { return }
        let wanted = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
            volume(of: source.id) < 0.995 ? (source.id, source) : nil
        })
        for (id, tap) in taps where wanted[id] == nil || Set(wanted[id]!.processes) != tap.processes {
            tap.invalidate()
            taps[id] = nil
        }
        // Bestehende Abzweigungen laufen nur, solange die App wirklich Ton abspielt.
        for (id, tap) in taps { tap.running = wanted[id]?.isPlaying ?? false }
        guard !wanted.isEmpty else { return problem = nil }
        guard let output = CoreAudio.defaultOutputUID() else { return problem = "Kein Ausgabegerät gefunden" }
        for (id, source) in wanted where taps[id] == nil {
            do {
                taps[id] = try ProcessTap(processes: source.processes, outputUID: output, gain: volume(of: id),
                                          running: source.isPlaying)
                Log.write("Lautstärke – \(source.name) auf \(Int(volume(of: id) * 100)) %")
                problem = nil
            } catch {
                problem = "\(source.name): \(error.localizedDescription)"
                Log.write("Lautstärke – \(source.name) fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    private func rebuildTaps() {
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
        applyTaps()
    }
}

// MARK: - Abzweigung einer App

/// Zapft den Ton einiger Prozesse ab (das Original wird stumm) und spielt ihn mit `gain`
/// über ein privates Sammelgerät auf dem Ausgabegerät ab.
final class ProcessTap: @unchecked Sendable {
    let processes: Set<AudioObjectID>
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Ziel- und aktuelle Lautstärke; der Ton-Thread gleitet langsam zum Ziel, damit es nicht knackt.
    private let level = UnsafeMutablePointer<Float>.allocate(capacity: 2)

    /// Nur während die App spielt, läuft die Wiedergabe. Sonst ruht alles, auch das Ausgabegerät
    /// wird nicht wachgehalten. Das Original bleibt dabei stumm, damit es beim Start nicht kurz laut ist.
    var running = false {
        didSet {
            guard running != oldValue, aggregateID != kAudioObjectUnknown, let procID else { return }
            if running { AudioDeviceStart(aggregateID, procID) } else { AudioDeviceStop(aggregateID, procID) }
        }
    }

    var gain: Float {
        get { level[0] }
        set { level[0] = newValue }
    }

    init(processes: [AudioObjectID], outputUID: String, gain: Float, running: Bool) throws {
        self.processes = Set(processes)
        level[0] = gain
        level[1] = gain

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Rook"
        description.isPrivate = true
        description.muteBehavior = .muted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Abzweigung")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rook Lautstärke",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Sammelgerät")
            let level = self.level
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
                ProcessTap.render(input, output, level)
            }, "Wiedergabe")
            if running { try check(AudioDeviceStart(aggregateID, procID), "Start") }
            self.running = running
        } catch {
            invalidate()
            throw error
        }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                if running { AudioDeviceStop(aggregateID, procID) }
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        invalidate()
        level.deallocate()
    }

    /// Läuft im Ton-Thread: Ton der Abzweigung (Stereo, Float) mal Lautstärke in die Ausgabe.
    /// Die Ausgabe kann ein Puffer mit mehreren Kanälen oder je Kanal ein Puffer sein.
    private static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>,
                               _ level: UnsafeMutablePointer<Float>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let target = level[0]
        var current = level[1]

        guard let source = inputs.first, let sourceData = source.mData?.assumingMemoryBound(to: Float.self) else {
            for buffer in outputs { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
            return
        }
        let sourceChannels = max(Int(source.mNumberChannels), 1)
        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / sourceChannels
        let step = frames > 0 ? (target - current) / Float(frames) : 0

        var firstChannel = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            let count = min(frames, capacity)
            var gain = current
            for frame in 0..<count {
                for channel in 0..<channels {
                    let from = min(firstChannel + channel, sourceChannels - 1)
                    data[frame * channels + channel] = sourceData[frame * sourceChannels + from] * gain
                }
                gain += step
            }
            if count < capacity { memset(data + count * channels, 0, (capacity - count) * channels * MemoryLayout<Float>.size) }
            firstChannel += channels
        }
        current = target
        level[1] = current
    }
}

private struct AudioError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) fehlgeschlagen (\(status))" }
}

private func check(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw AudioError(step: step, status: status) }
}

// MARK: - Core-Audio-Abfragen

private enum CoreAudio {
    static func processObjects() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    static func pid(of object: AudioObjectID) -> pid_t? {
        var pid: pid_t = -1
        return get(object, kAudioProcessPropertyPID, &pid) && pid > 0 ? pid : nil
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        return get(object, kAudioProcessPropertyIsRunningOutput, &running) && running != 0
    }

    static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
              device != kAudioObjectUnknown else { return nil }
        var uid: Unmanaged<CFString>?
        guard get(device, kAudioDevicePropertyDeviceUID, &uid), let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }
}

/// Zu welcher App gehört ein Hilfsprozess (z. B. der Ton-Prozess eines Browsers)?
/// macOS führt das als „verantwortlichen Prozess“; die Abfrage ist nicht öffentlich.
private enum Responsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    nonisolated(unsafe) private static let lookup: Lookup? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                                   "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Lookup.self) }

    static func app(for pid: pid_t) -> pid_t {
        guard let lookup else { return pid }
        let responsible = lookup(pid)
        return responsible > 0 ? responsible : pid
    }
}
