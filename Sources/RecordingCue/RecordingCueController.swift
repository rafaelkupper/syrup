import AppKit
import SwiftUI

/// What the floating cue should be showing, derived from the pipeline state.
enum RecordingCueState: Equatable, Sendable {
    case hidden
    case recording(caption: String?)
    case processing
    case success
    case error(String)
}

@MainActor
protocol RecordingCuePresenting: AnyObject, Sendable {
    func apply(_ state: RecordingCueState)
    func updateLevel(_ level: Double)
    func updateTranscript(_ text: String)
    func updateOutput(_ text: String) -> Bool
}

extension RecordingCuePresenting {
    func updateOutput(_ text: String) -> Bool { false }
}

/// Owns the floating bottom-center cue: a borderless, click-through panel that
/// joins every Space and mirrors the pipeline — live wave while recording, a
/// breathing line while processing, then a success or error flash.
@MainActor
final class RecordingCueController: RecordingCuePresenting {
    private static let panelSize = NSSize(width: 460, height: 92)
    private static let bottomMargin: CGFloat = 24
    private static let fadeDuration: TimeInterval = 0.18

    private let model = RecordingCueModel()
    private let typewriterIntervalNanoseconds: UInt64
    private var panel: NSPanel?
    private var currentState: RecordingCueState = .hidden
    private var hideTask: Task<Void, Never>?
    private var typewriter = TranscriptTypewriter()
    private var typewriterGeneration = 0
    private var typewriterTask: Task<Void, Never>?

    init(typewriterIntervalNanoseconds: UInt64 = 28_000_000) {
        self.typewriterIntervalNanoseconds = typewriterIntervalNanoseconds
    }

    func apply(_ state: RecordingCueState) {
        guard state != currentState else { return }
        let previousState = currentState
        currentState = state

        switch state {
        case .hidden:
            typewriterGeneration += 1
            typewriterTask?.cancel()
            typewriterTask = nil
            typewriter.reset()
            model.transcript = ""
            model.phase = .hidden
            fadeOut()
        case .recording(let caption):
            model.isOutputPreview = false
            model.level = 0
            model.transcript = ""
            typewriterGeneration += 1
            typewriterTask?.cancel()
            typewriterTask = nil
            typewriter.reset()
            model.recordingStartedAt = Date()
            model.phase = .recording(caption: caption)
            fadeIn(repositioning: previousState == .hidden)
        case .processing:
            typewriterGeneration += 1
            typewriterTask?.cancel()
            typewriterTask = nil
            typewriter.reset()
            model.transcript = ""
            model.isOutputPreview = false
            model.phase = .processing
            fadeIn(repositioning: previousState == .hidden)
        case .success:
            model.phase = .success
            fadeIn(repositioning: previousState == .hidden)
        case .error(let message):
            model.phase = .error(message)
            fadeIn(repositioning: previousState == .hidden)
        }
    }

    func updateLevel(_ level: Double) {
        model.level = level
    }

    func updateTranscript(_ text: String) {
        guard case .recording = currentState else { return }
        typewriter.target = text
        startTypewriterIfNeeded()
    }

    func updateOutput(_ text: String) -> Bool {
        guard currentState == .processing else { return false }
        let preview = String(text.suffix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard preview.isEmpty == false else { return false }
        model.isOutputPreview = true
        model.transcript = preview
        return true
    }

    private func startTypewriterIfNeeded() {
        guard typewriterTask == nil else { return }

        typewriterGeneration += 1
        let generation = typewriterGeneration
        typewriterTask = Task { [weak self] in
            while let self, Task.isCancelled == false {
                let hasMore = self.typewriter.advance()
                self.model.transcript = self.typewriter.displayed
                guard hasMore else { break }
                try? await Task.sleep(nanoseconds: self.typewriterIntervalNanoseconds)
            }
            if self?.typewriterGeneration == generation { self?.typewriterTask = nil }
        }
    }

    private func fadeIn(repositioning: Bool) {
        hideTask?.cancel()
        hideTask = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        if repositioning {
            position(panel)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, Task.isCancelled == false, self.currentState == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        let hostingView = NSHostingView(
            rootView: RecordingCueView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        )
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.minY + Self.bottomMargin
        )
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }
}
