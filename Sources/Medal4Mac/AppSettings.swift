import Carbon.HIToolbox
import Foundation

let clipLengths = [10, 30, 60, 120, 180]

func clipLengthTitle(_ seconds: Int) -> String {
    switch seconds {
    case ..<60: return "\(seconds) Seconds"
    case 60: return "1 Minute"
    default: return "\(seconds / 60) Minutes"
    }
}

func clipLengthShort(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
}

enum ResolutionOption: String, CaseIterable {
    case native, p1440, p1080, p720

    var title: String {
        switch self {
        case .native: return "Native (sharpest, biggest files)"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .native: return nil
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}

enum QualityOption: String, CaseIterable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: return "Low (small files)"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.05
        case .medium: return 0.09
        case .high: return 0.15
        }
    }
}

struct HotKeyPreset {
    let id: String
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
}

let hotKeyPresets: [HotKeyPreset] = [
    HotKeyPreset(id: "opt-c", title: "⌥C (Option + C)", keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(optionKey)),
    HotKeyPreset(id: "ctrl-opt-c", title: "⌃⌥C (Control + Option + C)", keyCode: UInt32(kVK_ANSI_C),
                 modifiers: UInt32(controlKey | optionKey)),
    HotKeyPreset(id: "f8", title: "F8", keyCode: UInt32(kVK_F8), modifiers: 0),
    HotKeyPreset(id: "f9", title: "F9", keyCode: UInt32(kVK_F9), modifiers: 0),
    HotKeyPreset(id: "f10", title: "F10", keyCode: UInt32(kVK_F10), modifiers: 0),
]

/// Ctrl+Option+1…5 always save a specific length (10s, 30s, 1m, 2m, 3m).
let durationKeyCodes: [UInt32] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].map { UInt32($0) }
let durationModifiers = UInt32(controlKey | optionKey)

final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var resolution: ResolutionOption {
        get { ResolutionOption(rawValue: defaults.string(forKey: "resolution") ?? "") ?? .p1080 }
        set { defaults.set(newValue.rawValue, forKey: "resolution") }
    }

    var quality: QualityOption {
        get { QualityOption(rawValue: defaults.string(forKey: "quality") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "quality") }
    }

    var fps: Int {
        get {
            let value = defaults.integer(forKey: "fps")
            return value == 30 || value == 60 ? value : 60
        }
        set { defaults.set(newValue, forKey: "fps") }
    }

    var captureAudio: Bool {
        get { defaults.object(forKey: "captureAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "captureAudio") }
    }

    var defaultClipSeconds: Int {
        get {
            let value = defaults.integer(forKey: "defaultClipSeconds")
            return clipLengths.contains(value) ? value : 30
        }
        set { defaults.set(newValue, forKey: "defaultClipSeconds") }
    }

    var hotKeyPreset: HotKeyPreset {
        get {
            let id = defaults.string(forKey: "hotKeyPreset") ?? ""
            return hotKeyPresets.first { $0.id == id } ?? hotKeyPresets[0]
        }
        set { defaults.set(newValue.id, forKey: "hotKeyPreset") }
    }

    var captureOptions: CaptureOptions {
        CaptureOptions(
            maxHeight: resolution.maxHeight,
            fps: fps,
            bitsPerPixel: quality.bitsPerPixel,
            captureAudio: captureAudio)
    }

    /// ~/Movies/Medal4Mac
    var clipsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Medal4Mac", isDirectory: true)
    }

    func newClipURL(seconds: Int) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Clip \(formatter.string(from: Date())) (\(clipLengthShort(seconds))).mp4"
        return clipsFolder.appendingPathComponent(name)
    }
}
