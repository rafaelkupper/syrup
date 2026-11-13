import SwiftUI

struct OnboardingPalette {
    let background: Color
    let ink: Color
    let secondaryInk: Color
    let card: Color
    let line: Color
    let field: Color
    let off: Color
    let tint: Color
    let accent: Color

    static let syrup = Color(red: 0.93, green: 0.52, blue: 0.07)
    static let buttonInk = Color(red: 0.24, green: 0.10, blue: 0.01)

    static func forScheme(_ scheme: ColorScheme) -> OnboardingPalette {
        scheme == .dark
            ? OnboardingPalette(
                background: Color(red: 0.16, green: 0.09, blue: 0.03),
                ink: Color(red: 1.00, green: 0.93, blue: 0.82),
                secondaryInk: Color(red: 0.76, green: 0.63, blue: 0.49),
                card: Color(red: 0.21, green: 0.12, blue: 0.06),
                line: Color(red: 0.31, green: 0.19, blue: 0.09),
                field: Color(red: 0.13, green: 0.07, blue: 0.04),
                off: Color(red: 0.33, green: 0.20, blue: 0.09),
                tint: Color(red: 0.29, green: 0.17, blue: 0.07),
                accent: Color(red: 0.96, green: 0.65, blue: 0.16)
            )
            : OnboardingPalette(
                background: Color(red: 1.00, green: 0.97, blue: 0.92),
                ink: Color(red: 0.31, green: 0.15, blue: 0.02),
                secondaryInk: Color(red: 0.49, green: 0.32, blue: 0.16),
                card: Color(red: 1.00, green: 0.99, blue: 0.97),
                line: Color(red: 0.94, green: 0.87, blue: 0.77),
                field: .white,
                off: Color(red: 0.92, green: 0.85, blue: 0.74),
                tint: Color(red: 0.98, green: 0.91, blue: 0.78),
                accent: Color(red: 0.66, green: 0.35, blue: 0.02)
            )
    }
}

/// The syrup running down from the top of the window.
struct DripBand: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let bandHeight: CGFloat = 24
    private static let drips: [(left: CGFloat, width: CGFloat, length: CGFloat)] = [
        (30, 13, 10), (64, 10, 26), (96, 15, 14), (138, 11, 38), (174, 13, 12), (218, 10, 14), (256, 16, 10),
        (302, 10, 14), (334, 13, 12), (378, 10, 42), (410, 15, 16), (456, 10, 30), (492, 14, 12),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
            Canvas { canvas, size in
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                draw(in: &canvas, size: size, time: time)
            }
        }
        .frame(height: 84)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let tip = { (drip: (left: CGFloat, width: CGFloat, length: CGFloat)) in
            Self.bandHeight + drip.length + sin(time / 1.4 + drip.left) * 3
        }
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: size.width, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: Self.bandHeight))
        for drip in Self.drips.reversed() {
            let radius = drip.width / 2
            let right = drip.left + drip.width
            let bottom = tip(drip)
            path.addLine(to: CGPoint(x: right, y: Self.bandHeight))
            path.addLine(to: CGPoint(x: right, y: bottom - radius))
            path.addArc(
                center: CGPoint(x: drip.left + radius, y: bottom - radius),
                radius: radius,
                startAngle: .degrees(0),
                endAngle: .degrees(180),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: drip.left, y: Self.bandHeight))
        }
        path.addLine(to: CGPoint(x: 0, y: Self.bandHeight))
        path.closeSubpath()
        canvas.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.90, green: 0.48, blue: 0.05), location: 0),
                .init(color: Color(red: 0.95, green: 0.60, blue: 0.12), location: 0.5),
                .init(color: Color(red: 1.00, green: 0.74, blue: 0.27), location: 1),
            ]),
            startPoint: .zero,
            endPoint: CGPoint(x: 0, y: size.height)
        ))
        for drip in Self.drips where drip.length > 25 {
            let gloss = CGRect(
                x: drip.left + drip.width * 0.22,
                y: tip(drip) - drip.width * 0.2 - 8,
                width: drip.width * 0.17,
                height: 7
            )
            canvas.fill(Path(roundedRect: gloss, cornerRadius: 1), with: .color(.white.opacity(0.5)))
        }
    }
}

/// The syrup drop that speaks for the app. Decorative, so hidden from VoiceOver.
struct SyrupDrop: View {
    enum Mood: Equatable {
        case smiling
        case listening
        case happy
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat
    var mood: Mood = .smiling

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
            Canvas { canvas, canvasSize in
                canvas.scaleBy(x: canvasSize.width / 120, y: canvasSize.height / 126)
                draw(in: &canvas, eyeOpenness: eyeOpenness(at: context.date))
            }
        }
        .frame(width: size, height: size * 1.05)
        .accessibilityHidden(true)
    }

    private func eyeOpenness(at date: Date) -> CGFloat {
        guard reduceMotion == false else { return 1 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) / 4.2
        return phase > 0.95 ? 0.1 : 1
    }

    private func draw(in canvas: inout GraphicsContext, eyeOpenness: CGFloat) {
        var body = Path()
        body.move(to: CGPoint(x: 60, y: 6))
        body.addCurve(to: CGPoint(x: 16, y: 80), control1: CGPoint(x: 60, y: 6), control2: CGPoint(x: 16, y: 52))
        body.addArc(center: CGPoint(x: 60, y: 80), radius: 44, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        body.addCurve(to: CGPoint(x: 60, y: 6), control1: CGPoint(x: 104, y: 52), control2: CGPoint(x: 60, y: 6))
        canvas.fill(body, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(red: 1.00, green: 0.84, blue: 0.44), location: 0),
                .init(color: Color(red: 0.97, green: 0.65, blue: 0.15), location: 0.55),
                .init(color: Color(red: 0.85, green: 0.41, blue: 0.04), location: 1),
            ]),
            center: CGPoint(x: 46, y: 53),
            startRadius: 0,
            endRadius: 96
        ))

        var gloss = Path()
        gloss.move(to: CGPoint(x: 36, y: 58))
        gloss.addCurve(to: CGPoint(x: 52, y: 32), control1: CGPoint(x: 39, y: 49), control2: CGPoint(x: 46, y: 39))
        canvas.stroke(gloss, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 6, lineCap: .round))

        let cheek = Color(red: 0.85, green: 0.28, blue: 0.06).opacity(0.32)
        canvas.fill(Path(ellipseIn: CGRect(x: 27.5, y: 80.5, width: 15, height: 9)), with: .color(cheek))
        canvas.fill(Path(ellipseIn: CGRect(x: 77.5, y: 80.5, width: 15, height: 9)), with: .color(cheek))

        let dark = Color(red: 0.29, green: 0.12, blue: 0.02)
        if mood == .happy {
            var eyes = Path()
            eyes.move(to: CGPoint(x: 42, y: 72))
            eyes.addQuadCurve(to: CGPoint(x: 54, y: 72), control: CGPoint(x: 48, y: 64))
            eyes.move(to: CGPoint(x: 66, y: 72))
            eyes.addQuadCurve(to: CGPoint(x: 78, y: 72), control: CGPoint(x: 72, y: 64))
            canvas.stroke(eyes, with: .color(dark), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        } else {
            for x: CGFloat in [48, 72] {
                let height = 14 * eyeOpenness
                canvas.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: 72 - height / 2, width: 11, height: height)), with: .color(dark))
                if eyeOpenness == 1 {
                    canvas.fill(Path(ellipseIn: CGRect(x: x - 0.2, y: 66.8, width: 4.4, height: 4.4)), with: .color(.white))
                }
            }
        }

        if mood == .listening {
            canvas.fill(Path(ellipseIn: CGRect(x: 55, y: 81, width: 10, height: 12)), with: .color(Color(red: 0.48, green: 0.17, blue: 0.03)))
        } else {
            var mouth = Path()
            mouth.move(to: CGPoint(x: 53, y: 84))
            mouth.addQuadCurve(to: CGPoint(x: 67, y: 84), control: CGPoint(x: 60, y: 91))
            canvas.stroke(mouth, with: .color(dark), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        }
    }
}

/// The drop's arrival on the welcome page: it falls, squashes, and settles.
struct FallingDrop: View {
    private struct Pose {
        var offset: CGFloat = -140
        var scaleX: CGFloat = 0.8
        var scaleY: CGFloat = 1.2
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasArrived = false
    let size: CGFloat

    var body: some View {
        if reduceMotion {
            SyrupDrop(size: size)
        } else {
            SyrupDrop(size: size)
                .keyframeAnimator(initialValue: Pose(), trigger: hasArrived) { content, pose in
                    content
                        .scaleEffect(x: pose.scaleX, y: pose.scaleY, anchor: UnitPoint(x: 0.5, y: 0.92))
                        .offset(y: pose.offset)
                } keyframes: { _ in
                    KeyframeTrack(\.offset) {
                        CubicKeyframe(0, duration: 0.55)
                        LinearKeyframe(0, duration: 0.12)
                        CubicKeyframe(-10, duration: 0.14)
                        CubicKeyframe(0, duration: 0.14)
                    }
                    KeyframeTrack(\.scaleX) {
                        CubicKeyframe(0.92, duration: 0.55)
                        CubicKeyframe(1.18, duration: 0.12)
                        CubicKeyframe(0.96, duration: 0.14)
                        CubicKeyframe(1, duration: 0.14)
                    }
                    KeyframeTrack(\.scaleY) {
                        CubicKeyframe(1.08, duration: 0.55)
                        CubicKeyframe(0.8, duration: 0.12)
                        CubicKeyframe(1.05, duration: 0.14)
                        CubicKeyframe(1, duration: 0.14)
                    }
                }
                .onAppear { hasArrived = true }
        }
    }
}

/// A short fall of amber sprinkles for the first result.
struct SyrupSprinkles: View {
    private struct Sprinkle {
        let x: CGFloat
        let delay: TimeInterval
        let duration: TimeInterval
        let spin: Double
        let color: Color
    }

    private static let colors = [
        Color(red: 0.97, green: 0.65, blue: 0.15), Color(red: 1.00, green: 0.84, blue: 0.44),
        Color(red: 0.85, green: 0.41, blue: 0.04), Color(red: 1.00, green: 0.95, blue: 0.84),
    ]

    @State private var startedAt = Date.now
    @State private var sprinkles: [Sprinkle] = (0..<30).map { index in
        Sprinkle(
            x: .random(in: 0...1),
            delay: .random(in: 0...0.5),
            duration: .random(in: 1.3...2.5),
            spin: .random(in: 3...10),
            color: colors[index % colors.count]
        )
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                let elapsed = context.date.timeIntervalSince(startedAt)
                for sprinkle in sprinkles {
                    let progress = (elapsed - sprinkle.delay) / sprinkle.duration
                    guard (0...1).contains(progress) else { continue }
                    var layer = canvas
                    layer.translateBy(x: sprinkle.x * size.width, y: progress * (size.height + 20) - 10)
                    layer.rotate(by: .radians(progress * sprinkle.spin))
                    let shape = Path(roundedRect: CGRect(x: -2, y: -5.5, width: 4, height: 11), cornerRadius: 2)
                    layer.fill(shape, with: .color(sprinkle.color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct SyrupButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 24 ? 13 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(OnboardingPalette.buttonInk)
            .padding(.horizontal, height > 24 ? 14 : 10)
            .frame(height: height)
            .background(
                LinearGradient(
                    colors: [Color(red: 1.00, green: 0.75, blue: 0.31), Color(red: 0.95, green: 0.60, blue: 0.12)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule()
            )
            .overlay(alignment: .top) {
                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .shadow(color: Color(red: 0.78, green: 0.40, blue: 0.04).opacity(0.25), radius: 1.5, y: 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
    }
}
