import Foundation

/// Minimal radix-2 FFT in pure Swift (portable: iOS, macOS, Linux, Windows).
/// 32 transforms of 2048 points per second cost well under 1 % CPU on an iPhone.
public final class FFT {
    public let n: Int
    private let log2n: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]

    public init(log2n: Int) {
        self.log2n = log2n
        n = 1 << log2n
        var c = [Float](repeating: 0, count: n / 2)
        var s = [Float](repeating: 0, count: n / 2)
        for j in 0..<(n / 2) {
            let angle = 2.0 * Double.pi * Double(j) / Double(n)
            c[j] = Float(cos(angle))
            s[j] = Float(sin(angle))
        }
        cosTable = c
        sinTable = s
        var rev = [Int](repeating: 0, count: n)
        for i in 0..<n {
            var x = i
            var r = 0
            for _ in 0..<log2n {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            rev[i] = r
        }
        bitReverse = rev
    }

    /// In-place forward transform.
    public func forward(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n {
            let j = bitReverse[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        var size = 2
        while size <= n {
            let half = size / 2
            let step = n / size
            var start = 0
            while start < n {
                for k in 0..<half {
                    let tr = cosTable[k * step]
                    let ti = -sinTable[k * step]
                    let a = start + k
                    let b = a + half
                    let xr = re[b] * tr - im[b] * ti
                    let xi = re[b] * ti + im[b] * tr
                    re[b] = re[a] - xr
                    im[b] = im[a] - xi
                    re[a] += xr
                    im[a] += xi
                }
                start += size
            }
            size *= 2
        }
    }
}

/// Turns a 16 kHz mono float stream into one `FrameFeatures` per second
/// (classifier fields, `t` and noise floor are filled in later by the pipeline).
public final class FeatureExtractor {
    public static let sampleRate = 16_000
    private let n = 2048
    private let hop = 500                 // 32 sub-frames per second exactly
    private let subPerSecond = 32
    private let subPerEnvelope = 8        // 4 envelope values per second
    private let fft = FFT(log2n: 11)
    private let window: [Float]

    private var history: [Float]
    private var historyPos = 0
    private var sinceHop = 0
    private var subIndex = 0

    private var re: [Float]
    private var im: [Float]
    private var power: [Float]
    private var previousMagnitude: [Float]
    private var recentSubEnergy: [Float] = []

    // per-second accumulators
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var sampleCount = 0
    private var bandSums: [Double] = [0, 0, 0, 0]
    private var flatnessSum: Double = 0
    private var fluxSum: Double = 0
    private var onsetCount = 0
    private var envelopeAccumulator: Double = 0
    private var envelope: [Float] = []

    // bin ranges at 7.8125 Hz per bin
    private let bands: [(Int, Int)] = [(8, 32), (32, 128), (128, 512), (512, 1024)]
    private let flatnessRange = (32, 1024)
    private let envelopeRange = (13, 192)

    public init() {
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            w[i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(n - 1)))
        }
        window = w
        history = [Float](repeating: 0, count: n)
        re = [Float](repeating: 0, count: n)
        im = [Float](repeating: 0, count: n)
        power = [Float](repeating: 0, count: n / 2 + 1)
        previousMagnitude = [Float](repeating: 0, count: n / 2 + 1)
    }

    /// Feed any number of samples; returns the seconds completed by this call.
    public func process(_ samples: [Float]) -> [FrameFeatures] {
        var out: [FrameFeatures] = []
        for s in samples {
            history[historyPos] = s
            historyPos = (historyPos + 1) % n
            sumSquares += Double(s * s)
            let a = abs(s)
            if a > peak { peak = a }
            sampleCount += 1
            sinceHop += 1
            if sinceHop == hop {
                sinceHop = 0
                analyzeSubFrame()
                subIndex += 1
                if subIndex == subPerSecond {
                    out.append(finishSecond())
                    subIndex = 0
                }
            }
        }
        return out
    }

    private func analyzeSubFrame() {
        for i in 0..<n {
            re[i] = history[(historyPos + i) % n] * window[i]
            im[i] = 0
        }
        fft.forward(&re, &im)
        let half = n / 2
        var total: Double = 0
        var magSum: Double = 0
        var flux: Double = 0
        for k in 0...half {
            let p = re[k] * re[k] + im[k] * im[k]
            power[k] = p
            total += Double(p)
            let m = p.squareRoot()
            magSum += Double(m)
            let d = m - previousMagnitude[k]
            if d > 0 { flux += Double(d) }
            previousMagnitude[k] = m
        }
        for (i, band) in bands.enumerated() {
            var sum: Double = 0
            for k in band.0..<band.1 { sum += Double(power[k]) }
            bandSums[i] += sum
        }
        var logSum: Double = 0
        var linSum: Double = 0
        let eps = 1e-12
        for k in flatnessRange.0..<flatnessRange.1 {
            let p = Double(power[k]) + eps
            logSum += log(p)
            linSum += p
        }
        let count = Double(flatnessRange.1 - flatnessRange.0)
        let flatness = exp(logSum / count) / (linSum / count)
        flatnessSum += flatness
        let normalisedFlux = flux / (magSum + 1e-9)
        fluxSum += normalisedFlux

        let subEnergyDb = Float(10 * log10(total / Double(n) + eps))
        if recentSubEnergy.count >= 8 {
            let sorted = recentSubEnergy.sorted()
            let median = sorted[sorted.count / 2]
            if subEnergyDb - median >= 6 && normalisedFlux >= 0.1 { onsetCount += 1 }
        }
        recentSubEnergy.append(subEnergyDb)
        if recentSubEnergy.count > 32 { recentSubEnergy.removeFirst() }

        var env: Double = 0
        for k in envelopeRange.0..<envelopeRange.1 { env += Double(power[k]) }
        envelopeAccumulator += env
        if (subIndex + 1) % subPerEnvelope == 0 {
            envelope.append(Float(10 * log10(envelopeAccumulator / Double(subPerEnvelope) + eps)))
            envelopeAccumulator = 0
        }
    }

    private func finishSecond() -> FrameFeatures {
        let eps = 1e-12
        let rms = sumSquares / Double(max(sampleCount, 1))
        var f = FrameFeatures()
        f.levelDb = Float(10 * log10(rms + eps))
        f.peakDb = Float(20 * log10(Double(peak) + 1e-9))
        let bandDb = bandSums.map { Float(10 * log10($0 / Double(subPerSecond) + eps)) }
        f.bandLow = bandDb[0]
        f.bandMid = bandDb[1]
        f.bandHigh = bandDb[2]
        f.bandAir = bandDb[3]
        f.flatness = Float(flatnessSum / Double(subPerSecond))
        f.flux = Float(fluxSum / Double(subPerSecond))
        f.onsets = Float(onsetCount)
        var env = envelope
        while env.count < 4 { env.append(env.last ?? -90) }
        f.env = Array(env.prefix(4))

        sumSquares = 0
        peak = 0
        sampleCount = 0
        bandSums = [0, 0, 0, 0]
        flatnessSum = 0
        fluxSum = 0
        onsetCount = 0
        envelope.removeAll(keepingCapacity: true)
        envelopeAccumulator = 0
        return f
    }
}

/// Rolling low percentile of the level = background noise floor.
public struct NoiseFloorTracker: Sendable {
    private var values: [Float]
    private var position = 0
    private var filled = 0
    private let percentile: Float

    public init(capacity: Int = 300, percentile: Float = 0.1) {
        values = [Float](repeating: 0, count: capacity)
        self.percentile = percentile
    }

    /// Adds a level value and returns the current floor.
    public mutating func push(_ level: Float) -> Float {
        values[position] = level
        position = (position + 1) % values.count
        filled = min(filled + 1, values.count)
        let sorted = values[0..<filled].sorted()
        let index = Int(Float(filled - 1) * percentile)
        return sorted[index]
    }
}
