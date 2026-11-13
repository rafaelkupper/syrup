import SwiftUI

enum RecordingCuePhase: Equatable {
    case hidden
    case recording(caption: String?)
    case processing
    case success
    case error(String)

    var showsWave: Bool {
        switch self {
        case .recording, .processing:
            true
        case .hidden, .success, .error:
            false
        }
    }
}

@MainActor
@Observable
final class RecordingCueModel {
    var phase: RecordingCuePhase = .hidden
    var level: Double = 0
    var transcript: String = ""
    var isOutputPreview = false
    var recordingStartedAt: Date?
}

/// The floating cue at the bottom of the screen: a dark capsule that shows a
/// live wave plus the words heard so far while recording, a calm breathing
/// line while the pipeline processes, and a success or error flash at the end.
struct RecordingCueView: View {
    let model: RecordingCueModel

    private static let escHintDelay: TimeInterval = 5

    // Per-frame interpolation state. A reference type so the Canvas closure
    // can advance it without triggering SwiftUI invalidation.
    private final class RenderState {
        var displayedEnergy: Double = 0
        var lastFrameTime: TimeInterval?
    }

    @State private var renderState = RenderState()

    private struct WaveLayer {
        let speed: Double
        let frequency: Double
        let weight: Double
        let opacity: Double
    }

    private static let layers = [
        WaveLayer(speed: 2.6, frequency: 2.4, weight: 1.0, opacity: 0.95),
        WaveLayer(speed: -1.9, frequency: 3.1, weight: 0.55, opacity: 0.35),
    ]

    /// Coarse phase identity used to drive pill content transitions without
    /// re-triggering them on caption or message changes.
    private enum PhaseKind: Equatable {
        case wave
        case success
        case error
        case hidden
    }

    private var phaseKind: PhaseKind {
        switch model.phase {
        case .recording, .processing:
            .wave
        case .success:
            .success
        case .error:
            .error
        case .hidden:
            .hidden
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: model.phase == .hidden)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            VStack(spacing: 7) {
                caption(at: timeline.date)
                pill(time: time)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: phaseKind)
            .animation(.easeInOut(duration: 0.22), value: captionText(at: timeline.date))
            .animation(.easeInOut(duration: 0.18), value: model.transcript.isEmpty)
        }
        .padding(.bottom, 2)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Caption

    @ViewBuilder
    private func caption(at date: Date) -> some View {
        if let text = captionText(at: date) {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .id(text)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func captionText(at date: Date) -> String? {
        if model.phase == .processing, model.isOutputPreview { return "Writing result" }
        guard case .recording(let caption) = model.phase else { return nil }

        if let startedAt = model.recordingStartedAt,
           date.timeIntervalSince(startedAt) > Self.escHintDelay {
            return "esc to cancel"
        }
        return caption
    }

    // MARK: - Pill

    @ViewBuilder
    private func pill(time: TimeInterval) -> some View {
        Group {
            switch model.phase {
            case .recording, .processing:
                waveRow(time: time)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            case .error(let message):
                errorRow(message: message)
                    .transition(.opacity)
            case .hidden:
                Color.clear.frame(width: 56, height: 20)
            }
        }
        .frame(minWidth: 56, minHeight: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.68)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
    }

    private func waveRow(time: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Canvas { context, size in
                drawWave(in: context, size: size, time: time)
            }
            .frame(width: 56, height: 20)

            if model.transcript.isEmpty == false {
                Text(model.transcript)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 210, alignment: .trailing)
                    .transition(.opacity)
            }
        }
    }

    private func errorRow(message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 280)
        }
    }

    // MARK: - Wave

    private func drawWave(in context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let isProcessing = model.phase == .processing
        // Recording follows the mic with a small idle floor so silence still
        // reads as "listening"; processing breathes gently on its own.
        let targetEnergy = isProcessing
            ? 0.09 + 0.05 * (0.5 + 0.5 * sin(time * 1.7))
            : 0.1 + 0.9 * model.level
        let energy = interpolatedEnergy(target: targetEnergy, at: time)
        let speedFactor = isProcessing ? 0.45 : 1.0

        let midY = size.height / 2
        let amplitude = (size.height / 2 - 1) * energy

        for layer in Self.layers {
            var path = Path()
            let step: CGFloat = 1.5
            var x: CGFloat = 0
            while x <= size.width {
                let progress = x / size.width
                let envelope = pow(sin(.pi * progress), 1.4)
                let angle = progress * .pi * 2 * layer.frequency
                    + time * layer.speed * speedFactor * .pi
                let y = midY + sin(angle) * amplitude * envelope * layer.weight
                if x == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                x += step
            }
            context.stroke(
                path,
                with: .color(.white.opacity(layer.opacity)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func interpolatedEnergy(target: Double, at time: TimeInterval) -> Double {
        let elapsed = min(max(time - (renderState.lastFrameTime ?? time), 0), 0.1)
        renderState.lastFrameTime = time

        let rate = target > renderState.displayedEnergy ? 14.0 : 6.0
        let alpha = 1 - exp(-rate * elapsed)
        renderState.displayedEnergy += (target - renderState.displayedEnergy) * alpha
        return renderState.displayedEnergy
    }

    private var accessibilityDescription: String {
        switch model.phase {
        case .hidden:
            ""
        case .recording:
            "Syrup is recording"
        case .processing:
            "Syrup is processing your dictation"
        case .success:
            "Dictation complete"
        case .error(let message):
            "Dictation failed: \(message)"
        }
    }
}
