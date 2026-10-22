import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

struct GroupConfidences {
    var snore: Float = 0
    var talk: Float = 0
    var cough: Float = 0
    var breathing: Float = 0
    var environment: Float = 0
    var topLabel: String = ""
    var topConfidence: Float = 0

    mutating func merge(_ o: GroupConfidences) {
        snore = max(snore, o.snore)
        talk = max(talk, o.talk)
        cough = max(cough, o.cough)
        breathing = max(breathing, o.breathing)
        environment = max(environment, o.environment)
        if o.topConfidence > topConfidence {
            topConfidence = o.topConfidence
            topLabel = o.topLabel
        }
    }
}

/// Maps Apple's built-in classifier labels (SNClassifierIdentifier.version1) to our groups.
/// Identifiers that do not exist in `knownClassifications` are simply never matched.
enum LabelMapping {
    static let snore: Set<String> = ["snoring"]
    static let talk: Set<String> = ["speech", "whispering", "shout", "yell", "screaming", "babble", "laughter", "giggling",
                                    "chuckle_chortle", "belly_laugh", "snicker", "crying_sobbing", "singing", "humming"]
    static let cough: Set<String> = ["cough", "sneeze", "nose_blowing", "throat_clearing"]
    static let breathing: Set<String> = ["breathing", "gasp", "sigh"]
    static let environmentPrefixes: [String] = [
        "dog", "cat", "bird", "baby", "door", "knock", "slam", "car_", "vehicle", "traffic", "siren", "horn", "truck",
        "bus", "motorcycle", "train", "aircraft", "airplane", "helicopter", "engine", "music", "television", "radio",
        "telephone", "ringtone", "alarm", "bell", "beep", "clock", "thunder", "rain", "wind", "water", "toilet",
        "footsteps", "person_walking", "person_running", "glass", "dishes", "cutlery", "keys", "typing", "applause",
    ]

    enum Group { case snore, talk, cough, breathing, environment, other }

    static func group(for label: String) -> Group {
        if snore.contains(label) { return .snore }
        if talk.contains(label) { return .talk }
        if cough.contains(label) { return .cough }
        if breathing.contains(label) { return .breathing }
        if environmentPrefixes.contains(where: { label.hasPrefix($0) }) { return .environment }
        return .other
    }
}

/// Thread-safe per-second store of classifier results (written on the analysis queue,
/// read on the pipeline queue).
final class ConfidenceStore {
    private let lock = NSLock()
    private var bySecond: [Int: GroupConfidences] = [:]

    func merge(second: Int, _ c: GroupConfidences) {
        lock.lock()
        defer { lock.unlock() }
        var current = bySecond[second] ?? GroupConfidences()
        current.merge(c)
        bySecond[second] = current
    }

    func take(second: Int) -> GroupConfidences {
        lock.lock()
        defer { lock.unlock() }
        let value = bySecond.removeValue(forKey: second) ?? GroupConfidences()
        if bySecond.count > 120 {
            for key in bySecond.keys where key < second - 60 { bySecond.removeValue(forKey: key) }
        }
        return value
    }
}

final class ClassifierObserver: NSObject, SNResultsObserving {
    private let store: ConfidenceStore
    private let secondForSample: (Int64) -> Int
    private let sampleRate: Double
    var onError: ((String) -> Void)?

    init(store: ConfidenceStore, sampleRate: Double, secondForSample: @escaping (Int64) -> Int) {
        self.store = store
        self.sampleRate = sampleRate
        self.secondForSample = secondForSample
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        var c = GroupConfidences()
        for item in r.classifications {
            let conf = Float(item.confidence)
            guard conf > 0.05 else { continue }
            switch LabelMapping.group(for: item.identifier) {
            case .snore: c.snore = max(c.snore, conf)
            case .talk: c.talk = max(c.talk, conf)
            case .cough: c.cough = max(c.cough, conf)
            case .breathing: c.breathing = max(c.breathing, conf)
            case .environment: c.environment = max(c.environment, conf)
            case .other: break
            }
            if conf > c.topConfidence && item.identifier != "silence" {
                c.topConfidence = conf
                c.topLabel = item.identifier
            }
        }
        let start = r.timeRange.start.seconds
        let duration = r.timeRange.duration.seconds
        guard start.isFinite, duration.isFinite else { return }
        let first = secondForSample(Int64(start * sampleRate))
        let last = secondForSample(Int64((start + max(duration, 0.1)) * sampleRate) - 1)
        if last >= first && last - first <= 20 {
            for s in first...last { store.merge(second: s, c) }
        } else {
            store.merge(second: first, c)
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        onError?("\(error)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}
