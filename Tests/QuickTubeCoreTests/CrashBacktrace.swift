import Darwin

/// Prints the faulting thread's stack to stderr when the test process dies on a signal, then lets the
/// signal take its default action. The Swift runtime's own backtracer refuses to run inside the
/// (privileged) test helper, and CI runners keep no crash reports, so without this a crash in an
/// AVFoundation end-to-end test leaves only "Exited with unexpected signal code N".
enum CrashBacktrace {
    /// Touch once before work that may crash; installing is idempotent.
    static let installed: Void = {
        _ = frameBuffer  // allocate now, not inside the handler
        for signal in [SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGABRT] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashHandler
            // One shot: when the handler returns the faulting instruction runs again and the default
            // action ends the process with the original signal.
            action.sa_flags = SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }()
}

/// Preallocated so the handler does not allocate.
private nonisolated(unsafe) let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(
    capacity: 256)

private let crashHandler: @convention(c) (Int32) -> Void = { signal in
    // Async-signal-safe only: no allocation, no locks (a SIGSEGV may come from inside malloc).
    emit("\n=== QuickTubeCoreTests: fatal signal ")
    var digits: (UInt8, UInt8, UInt8) = (0x20, 0x20, 0x30)
    var value = signal
    digits.2 = UInt8(0x30 + value % 10)
    value /= 10
    if value > 0 { digits.1 = UInt8(0x30 + value % 10) }
    _ = withUnsafeBytes(of: &digits) { write(STDERR_FILENO, $0.baseAddress, 3) }
    emit(", faulting thread backtrace ===\n")
    let count = backtrace(frameBuffer, 256)
    backtrace_symbols_fd(frameBuffer, count, STDERR_FILENO)
    emit("=== end of backtrace ===\n")
}

private func emit(_ text: StaticString) {
    _ = write(STDERR_FILENO, text.utf8Start, text.utf8CodeUnitCount)
}
