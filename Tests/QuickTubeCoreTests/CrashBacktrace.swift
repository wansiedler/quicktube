import Darwin

/// Prints the faulting thread's registers and frame-pointer chain to stderr when the test process dies
/// on a signal, then lets the signal take its default action. The Swift runtime's own backtracer refuses
/// to run inside the (privileged) test helper and CI runners keep no crash reports, so without this a
/// crash in an AVFoundation end-to-end test leaves only "Exited with unexpected signal code N".
///
/// `backtrace(3)` is not used: it walks through `_sigtramp` and itself trapped on the CI runner. The
/// chain is walked from the interrupted context instead, every read going through `vm_read_overwrite`
/// so a corrupt frame ends the walk rather than faulting again. The handler runs on its own stack, so a
/// stack overflow is reported too.
enum CrashBacktrace {
    static let signals = [SIGSEGV, SIGBUS, SIGTRAP, SIGILL, SIGFPE, SIGABRT]

    /// Touch once before work that may crash; installing is idempotent.
    static let installed: Void = {
        var stack = stack_t()
        stack.ss_sp = UnsafeMutableRawPointer.allocate(byteCount: 1 << 18, alignment: 16)
        stack.ss_size = 1 << 18
        stack.ss_flags = 0
        sigaltstack(&stack, nil)
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = crashHandler
            action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
    }()
}

private let crashHandler:
    @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = {
        signal, info, context in
        // A second fault while reporting must end the process, not re-enter here.
        for other in CrashBacktrace.signals { Darwin.signal(other, SIG_DFL) }
        emit("\n=== QuickTubeCoreTests: fatal signal ")
        emitNumber(UInt64(signal))
        emit(" code ")
        emitNumber(UInt64(UInt32(bitPattern: info?.pointee.si_code ?? 0)))
        emit(" addr ")
        emitAddress(UInt64(UInt(bitPattern: info?.pointee.si_addr)))
        emit(" ===\n")
        #if arch(arm64)
        if let context {
            let state = context.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext.pointee.__ss
            emitFrame(0, state.__pc)
            emitFrame(1, state.__lr)
            var frame = state.__fp
            var index = 2
            // Each frame record is {previous fp, return address}.
            while frame != 0, index < 64 {
                var record: (UInt64, UInt64) = (0, 0)
                var read: vm_size_t = 0
                let status = withUnsafeMutableBytes(of: &record) { buffer in
                    vm_read_overwrite(
                        mach_task_self_, vm_address_t(frame), vm_size_t(16),
                        vm_address_t(UInt(bitPattern: buffer.baseAddress)), &read)
                }
                guard status == KERN_SUCCESS, read == 16, record.1 != 0 else { break }
                emitFrame(index, record.1)
                guard record.0 > frame else { break }
                frame = record.0
                index += 1
            }
        }
        #endif
        emit("=== end of backtrace ===\n")
    }

/// `#n 0x… image symbol + offset`; `dladdr` is not formally signal-safe but only reads loader state.
private func emitFrame(_ index: Int, _ rawAddress: UInt64) {
    let address = rawAddress & 0x0000_7FFF_FFFF_FFFF  // strip pointer-authentication bits
    emit("#")
    emitNumber(UInt64(index))
    emit(" ")
    emitAddress(address)
    var symbol = Dl_info()
    if dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &symbol) != 0 {
        if let image = symbol.dli_fname {
            emit(" ")
            let base = strrchr(image, 0x2F).map { UnsafePointer($0 + 1) } ?? image
            _ = write(STDERR_FILENO, base, strlen(base))
        }
        if let name = symbol.dli_sname {
            emit(" ")
            _ = write(STDERR_FILENO, name, strlen(name))
            emit(" + ")
            emitNumber(address &- UInt64(UInt(bitPattern: symbol.dli_saddr)))
        }
    }
    emit("\n")
}

private func emit(_ text: StaticString) {
    _ = write(STDERR_FILENO, text.utf8Start, text.utf8CodeUnitCount)
}

private func emitNumber(_ value: UInt64) {
    var scratch: (UInt64, UInt64, UInt64) = (0, 0, 0)  // 24 bytes, no allocation
    withUnsafeMutableBytes(of: &scratch) { buffer in
        var value = value
        var start = buffer.count
        repeat {
            start -= 1
            buffer[start] = UInt8(0x30 + value % 10)
            value /= 10
        } while value > 0
        _ = write(STDERR_FILENO, buffer.baseAddress! + start, buffer.count - start)
    }
}

private func emitAddress(_ value: UInt64) {
    let hex: StaticString = "0123456789abcdef"
    var scratch: (UInt64, UInt64, UInt64) = (0, 0, 0)
    withUnsafeMutableBytes(of: &scratch) { buffer in
        buffer[0] = 0x30
        buffer[1] = 0x78
        for index in 0..<16 {
            buffer[2 + index] = hex.utf8Start[Int((value >> UInt64(60 - 4 * index)) & 0xF)]
        }
        _ = write(STDERR_FILENO, buffer.baseAddress!, 18)
    }
}
