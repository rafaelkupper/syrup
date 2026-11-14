// Measures how long the delivery-target focus check holds the main actor when the editor is hung.
// It mirrors DeliveryTarget.isCurrent(): before 2026-11-13 the Accessibility read ran on the main
// actor; now it runs on a detached task. Needs Accessibility trust for the terminal running it.
//
//   swiftc -O -swift-version 6 script/measure-focus-check.swift -o /tmp/measure-focus-check
//   open -g -j -a TextEdit; sleep 2
//   /tmp/measure-focus-check "$(pgrep -x TextEdit | head -1)"   # stops and resumes TextEdit itself
//
// Results for 2026-11-13 are in plans/syrup/2026-11-13/review-round-3.md.
import AppKit
import ApplicationServices

// Mirrors DeliveryTarget's focus check: before, it ran on the main actor; after, on a detached task.
nonisolated func focusedElement(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.1)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
          let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    let e = unsafeDowncast(v, to: AXUIElement.self); AXUIElementSetMessagingTimeout(e, 0.1); return e
}
struct Box: @unchecked Sendable { let element: AXUIElement }

@MainActor func run() async {
    let pid = pid_t(CommandLine.arguments[1])!
    guard let captured = focusedElement(pid) else { print("no focused element"); return }
    let box = Box(element: captured)
    kill(pid, SIGSTOP)
    defer { kill(pid, SIGCONT) }
    let clock = ContinuousClock()
    for mode in ["idle (no check)", "before (main actor)", "after (detached)", "idle (no check)"] {
        var maxGap = Duration.zero
        var running = true
        let ticker = Task { @MainActor in
            var last = clock.now
            while running {
                try? await Task.sleep(for: .milliseconds(1))
                let now = clock.now
                maxGap = max(maxGap, last.duration(to: now)); last = now
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        maxGap = .zero
        var totals: [Duration] = []
        for _ in 0..<10 {
            let start = clock.now
            if mode.hasPrefix("idle") { try? await Task.sleep(for: .milliseconds(100)) } else if mode.hasPrefix("before") {
                _ = focusedElement(pid).map { CFEqual(box.element, $0) } ?? false
            } else {
                _ = await Task.detached(priority: .userInitiated) {
                    focusedElement(pid).map { CFEqual(box.element, $0) } ?? false
                }.value
            }
            totals.append(start.duration(to: clock.now))
            try? await Task.sleep(for: .milliseconds(5))
        }
        running = false
        await ticker.value
        let ms = { (d: Duration) in Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let sorted = totals.map(ms).sorted()
        print(String(format: "%@: check latency p50 %.1f ms, longest main-actor stall %.1f ms", mode, sorted[5], ms(maxGap)))
    }
}
await run()
