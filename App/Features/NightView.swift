import SleepEngineCore
import SwiftUI

/// Full-screen night screen: black, dimmed clock, status dot, hold-to-stop.
struct NightView: View {
    @Environment(SessionController.self) private var controller
    @AppStorage(AppSettings.Key.showLevelMeter) private var showLevelMeter = true
    @State private var holdProgress: CGFloat = 0
    @State private var stopFeedback = 0

    private static let holdDuration = 1.5

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if controller.phase == .finishing {
                VStack(spacing: 16) {
                    ProgressView().tint(.white)
                    Text("Bericht wird erstellt …").foregroundStyle(.white.opacity(0.7))
                }
            } else {
                VStack(spacing: 24) {
                    statusRow
                    Spacer()
                    clock
                    windowText
                    if showLevelMeter { levelMeter }
                    Spacer()
                    if controller.wakeTriggered {
                        morningButton
                    }
                    holdToStop
                }
                .padding(24)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sensoryFeedback(.success, trigger: stopFeedback)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.captureOK ? Color.green : Color.yellow)
                .frame(width: 8, height: 8)
            Text(controller.captureOK ? "Aufnahme läuft" : "Aufnahme wird neu gestartet")
            Spacer()
            if controller.current?.isTest == true { Text("Testsession") }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.45))
        .accessibilityElement(children: .combine)
    }

    private var clock: some View {
        TimelineView(.everyMinute) { context in
            Text(Fmt.time(context.date))
                .font(.system(size: 88, weight: .thin, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
    }

    private var windowText: some View {
        Group {
            if let meta = controller.current {
                switch meta.mode {
                case .smart:
                    if let start = meta.windowStart, meta.windowMinutes > 0 {
                        Text("Weckfenster \(Fmt.time(start)) – \(Fmt.time(meta.latestWake))")
                    } else {
                        Text("Wecker \(Fmt.time(meta.latestWake))")
                    }
                case .regular:
                    Text("Wecker \(Fmt.time(meta.latestWake))")
                case .trackingOnly:
                    Text("Nur Tracking")
                }
            }
        }
        .font(.title3)
        .foregroundStyle(.white.opacity(0.4))
    }

    /// Level is dB above the noise floor (0 … ~40).
    private var levelMeter: some View {
        let fraction = CGFloat(min(max(controller.liveLevel, 0), 40) / 40)
        return VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(.white.opacity(0.3)).frame(width: max(geo.size.width * fraction, 4))
                }
            }
            .frame(width: 140, height: 4)
            if !controller.liveLabel.isEmpty {
                Text(controller.liveLabel).font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
        }
        .accessibilityHidden(true)
    }

    private var morningButton: some View {
        Button {
            Task { await controller.stopNight() }
        } label: {
            Text("Guten Morgen")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 20))
        .foregroundStyle(.black)
    }

    private var holdToStop: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "stop.fill").foregroundStyle(.white.opacity(0.5))
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: Self.holdDuration, perform: {
            stopFeedback += 1
            holdProgress = 0
            Task { await controller.stopNight() }
        }, onPressingChanged: { pressing in
            if pressing {
                withAnimation(.linear(duration: Self.holdDuration)) { holdProgress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
            }
        })
        .overlay(alignment: .bottom) {
            Text("Halten zum Beenden")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
                .fixedSize()
                .offset(y: 22)
        }
        .padding(.bottom, 24)
        .accessibilityLabel("Nacht beenden")
        .accessibilityHint("Gedrückt halten")
        .accessibilityAction { Task { await controller.stopNight() } }
    }
}
