@preconcurrency import Foundation
import Darwin
import XCTest
@testable import LumenEditorCore

final class ToolProcessRunnerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp", isDirectory: true)

    func testDirectArgvDoesNotInterpretShellSyntax() async throws {
        let runner = ToolProcessRunner()
        let result = try await withDeadline {
            try await runner.run(self.command(
                executable: "/bin/sh",
                arguments: [
                    "-c", "printf '%s\n' \"$1\"", "fixed-source",
                    "$(printf injected); still literal"
                ]
            ))
        }

        XCTAssertEqual(result.stdout, "$(printf injected); still literal\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSpawnPreservesWorkingDirectoryEnvironmentAndIsolatedGroup() async throws {
        let runner = ToolProcessRunner()
        let result = try await withDeadline {
            try await runner.run(ToolCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    #"set -- $(/bin/ps -o pgid= -p $$); printf '%s\n%s\n%s\n%s' "$(/bin/pwd -P)" "$LUMEN_SPAWN_TEST" "$1" "$$""#
                ],
                workingDirectoryURL: self.root,
                environment: ["LUMEN_SPAWN_TEST": "value with spaces"],
                timeout: 2,
                maximumStandardInputBytes: 0,
                maximumStandardOutputBytes: 1_024,
                maximumStandardErrorBytes: 1_024
            ))
        }

        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 4 else {
            return XCTFail("Unexpected spawn probe output: \(result.stdout)")
        }
        XCTAssertEqual(String(lines[0]), root.resolvingSymlinksInPath().path)
        XCTAssertEqual(String(lines[1]), "value with spaces")
        XCTAssertEqual(lines[2], lines[3], "spawned PID must be its process-group ID")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testMissingExecutableReportsSpawnFailureAndDoesNotConsumePermit() async throws {
        let runner = ToolProcessRunner(
            maximumConcurrentProcesses: 1,
            maximumPendingProcesses: 1
        )

        do {
            _ = try await withDeadline {
                try await runner.run(self.command(
                    executable: "/tmp/lumen-missing-\(UUID().uuidString)"
                ))
            }
            XCTFail("Expected launch failure")
        } catch let error as ToolProcessRunnerError {
            guard case let .launchFailed(detail) = error else {
                return XCTFail("Unexpected runner error: \(error)")
            }
            XCTAssertTrue(detail.contains("posix_spawn"))
            XCTAssertTrue(detail.contains("errno"))
        }

        let result = try await withDeadline {
            try await runner.run(self.command(
                executable: "/bin/sh", arguments: ["-c", "printf recovered"]
            ))
        }
        XCTAssertEqual(result.stdout, "recovered")
    }

    func testImmediateLeaderExitStillReapsDetachedGroupMember() async throws {
        let runner = ToolProcessRunner()
        let result = try await withDeadline {
            try await runner.run(self.command(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sleep 30 </dev/null >/dev/null 2>&1 & printf '%d' $!"
                ],
                timeout: 2,
                outputLimit: 1_024,
                gracefulTimeout: 0.02
            ))
        }

        guard let descendantPID = Int32(result.stdout), descendantPID > 1 else {
            return XCTFail("Expected descendant PID, got \(result.stdout)")
        }
        defer {
            if Darwin.kill(descendantPID, 0) == 0 {
                _ = Darwin.kill(descendantPID, SIGKILL)
            }
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            Darwin.kill(descendantPID, 0), -1,
            "detached descendant survived normal leader exit"
        )
        XCTAssertEqual(errno, ESRCH)
    }

    func testRapidShortLivedIsolatedProcessesAreReapedReliably() async throws {
        let runner = ToolProcessRunner()
        try await withDeadline(seconds: 10) {
            for _ in 0..<100 {
                let result = try await runner.run(self.command(
                    executable: "/usr/bin/true"
                ))
                XCTAssertEqual(result.exitCode, 0)
            }
        }
    }

    func testCancelAllAfterZeroExitBeforeDelayedNotificationPreservesSuccess() async throws {
        let exitNotification = SendableExpectation(XCTestExpectation(
            description: "kernel exit notification reached the state queue"
        ))
        let runner = ToolProcessRunner(
            processExitNotificationDelayForTesting: 1,
            processExitNotificationObservedForTesting: { exitNotification.fulfill() }
        )
        let operation = Task {
            try await runner.run(self.command(
                executable: "/bin/sh",
                arguments: ["-c", "/bin/sleep 0.05; exit 0"],
                timeout: 2
            ))
        }

        // The child is now a waitable zombie, while the test seam deliberately
        // holds the normal dispatch-source reap. cancelAll must synchronously
        // reap that exit before it records cancellation.
        await fulfillment(of: [exitNotification.expectation], timeout: 2)
        await runner.cancelAll()
        let result = try await withDeadline { try await operation.value }

        XCTAssertEqual(result.exitCode, 0)
    }

    func testValidatedShellCommandStreamsBoundedChunksAndDrainsBeforeTermination() async throws {
        let runner = ToolProcessRunner()
        let recorder = EventRecorder()
        let payloadSize = ToolExecutionLimits.maximumOutputChunkBytes + 17
        let shell = command(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "head -c \(payloadSize) /dev/zero | tr '\\0' x; printf err >&2"
            ],
            outputLimit: payloadSize + 1_024
        )

        let result = try await withDeadline(seconds: 5) {
            try await runner.run(shell) { stream, data in
                recorder.append(stream: stream, data: data)
            }
        }
        let events = recorder.snapshot()

        XCTAssertEqual(result.standardOutput, Data(repeating: 0x78, count: payloadSize))
        XCTAssertEqual(result.stderr, "err")
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.data.count <= ToolExecutionLimits.maximumOutputChunkBytes })
        let streamedOut = events
            .filter { $0.stream == .standardOutput }
            .reduce(into: Data()) { $0.append($1.data) }
        let streamedError = events
            .filter { $0.stream == .standardError }
            .reduce(into: Data()) { $0.append($1.data) }
        XCTAssertEqual(streamedOut, result.standardOutput)
        XCTAssertEqual(streamedError, result.standardError)
    }

    func testStreamingCallbackRunsOffLifecycleQueue() async throws {
        let runner = ToolProcessRunner(
            maximumPendingOutputDeliveryBytes: 1_024,
            maximumPendingOutputDeliveryChunks: 4
        )
        let callbackStarted = XCTestExpectation(description: "callback started")
        let releaseCallback = DispatchSemaphore(value: 0)
        let command = command(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            outputLimit: 1_024
        )
        let task = Task {
            try await runner.run(command) { _, _ in
                callbackStarted.fulfill()
                _ = releaseCallback.wait(timeout: .now() + 2)
            }
        }

        await fulfillment(of: [callbackStarted], timeout: 2)
        let cancelTask = Task { await runner.cancelAll() }
        releaseCallback.signal()
        _ = await cancelTask.value
        _ = try? await withDeadline { try await task.value }
    }

    func testInteractiveStdinIsSerializedAndClosedExplicitly() async throws {
        let runner = ToolProcessRunner(maximumQueuedStandardInputBytes: 1_024)
        let session = try await withDeadline {
            try await runner.start(self.command(
                executable: "/bin/sh",
                arguments: ["-c", "cat"],
                outputLimit: 1_024
            ))
        }

        try await session.write(Data("first".utf8))
        try await session.write(Data(" second".utf8))
        try await session.closeStandardInput()
        let result = try await withDeadline { try await session.waitForExit() }

        XCTAssertEqual(result.stdout, "first second")
        XCTAssertEqual(result.exitCode, 0)
        do {
            try await session.write(Data("late".utf8))
            XCTFail("Expected closed stdin")
        } catch let error as ToolProcessSessionError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testInteractiveInterruptSignalsProcessGroup() async throws {
        let runner = ToolProcessRunner(maximumQueuedStandardInputBytes: 1_024)
        let ready = XCTestExpectation(description: "shell started foreground child")
        let resumed = XCTestExpectation(description: "shell resumed after SIGINT")
        let recorder = EventRecorder()
        let session = try await withDeadline {
            try await runner.start(self.command(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap : INT; \"$1\" -c \"$2\"; printf S; "
                        + "IFS= read -r line; printf 'L%s' \"$line\"",
                    "outer-shell",
                    "/bin/sh",
                    "trap \"printf C; exit 42\" INT; printf R; "
                        + "while :; do sleep 30; done"
                ],
                timeout: 5,
                outputLimit: 1_024
            )) { stream, data in
                recorder.append(stream: stream, data: data)
                guard stream == .standardOutput else { return }
                if recorder.claimFirstStandardOutputByte(0x52) { ready.fulfill() }
                if recorder.claimFirstStandardOutputByte(0x53) { resumed.fulfill() }
            }
        }
        defer { session.cancel() }

        await fulfillment(of: [ready], timeout: 2)
        try await session.interrupt()
        await fulfillment(of: [resumed], timeout: 2)
        try await session.write(Data("hello\n".utf8))
        try await session.closeStandardInput()
        let result = try await withDeadline { try await session.waitForExit() }
        let streamedOutput = recorder.snapshot()
            .filter { $0.stream == .standardOutput }
            .reduce(into: Data()) { $0.append($1.data) }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(streamedOutput, result.standardOutput)
        XCTAssertTrue(result.stdout.contains("R"))
        XCTAssertTrue(result.stdout.contains("C"))
        XCTAssertTrue(result.stdout.contains("S"))
        XCTAssertTrue(result.stdout.contains("Lhello"))
    }

    func testStdinRejectsOversizedWriteAndQueueOverflow() async throws {
        let runner = ToolProcessRunner(maximumQueuedStandardInputBytes: 16)
        let session = try await withDeadline {
            try await runner.start(self.command(
                executable: "/bin/sh",
                arguments: ["-c", "sleep 1; cat >/dev/null"],
                timeout: 3
            ))
        }

        do {
            try await session.write(Data(repeating: 0, count: ToolExecutionLimits.maximumStdinWriteBytes + 1))
            XCTFail("Expected per-write rejection")
        } catch let error as ToolProcessSessionError {
            XCTAssertEqual(error, .writeTooLarge(
                actualBytes: ToolExecutionLimits.maximumStdinWriteBytes + 1,
                maximumBytes: ToolExecutionLimits.maximumStdinWriteBytes
            ))
        }

        do {
            try await session.write(Data(repeating: 0x61, count: 17))
            XCTFail("Expected queue overflow")
        } catch let error as ToolProcessSessionError {
            XCTAssertEqual(error, .queueOverflow(maximumBytes: 16))
        }

        session.cancel()
        await assertToolError(.cancelled) { _ = try await session.waitForExit() }
    }

    func testOneShotStdinClosesAndLargeInputIsChunked() async throws {
        let input = Data(repeating: 0x61, count: ToolExecutionLimits.maximumStdinWriteBytes + 37)
        let runner = ToolProcessRunner()
        let result = try await withDeadline {
            try await runner.run(self.command(
                executable: "/bin/sh",
                arguments: ["-c", "wc -c"],
                standardInput: input,
                inputLimit: input.count,
                outputLimit: 1_024
            ))
        }

        XCTAssertEqual(
            Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
            Optional(input.count)
        )
    }

    func testSeparateOutputLimitsTerminateProcess() async throws {
        let runner = ToolProcessRunner()
        do {
            _ = try await withDeadline {
                try await runner.run(self.command(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "head -c 4096 /dev/zero | tr '\\0' x; exec sleep 30"
                    ],
                    timeout: 3,
                    outputLimit: 1_024,
                    gracefulTimeout: 0.05
                ))
            }
            XCTFail("Expected output limit")
        } catch let error as ToolExecutionError {
            XCTAssertEqual(error, .outputLimitExceeded(
                stream: .standardOutput,
                maximumBytes: 1_024
            ))
        }
    }

    func testStreamingLimitIsSeparateFromRetainedResultLimit() async throws {
        let runner = ToolProcessRunner()
        let recorder = EventRecorder()
        let command = ToolCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 1234567890"],
            workingDirectoryURL: root, timeout: 2,
            maximumStandardInputBytes: 0,
            maximumStandardOutputBytes: 10,
            maximumRetainedStandardOutputBytes: 4,
            maximumStandardErrorBytes: 1_024
        )

        let result = try await withDeadline {
            try await runner.run(command) { stream, data in
                recorder.append(stream: stream, data: data)
            }
        }
        let streamed = recorder.snapshot()
            .filter { $0.stream == .standardOutput }
            .reduce(into: Data()) { $0.append($1.data) }

        XCTAssertEqual(String(decoding: streamed, as: UTF8.self), "1234567890")
        XCTAssertEqual(result.stdout, "1234")
    }

    func testStreamingStillEnforcesLifetimeOutputLimitWhenRetentionIsSmaller() async throws {
        let runner = ToolProcessRunner()
        let command = ToolCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 12345678901"],
            workingDirectoryURL: root, timeout: 2,
            maximumStandardInputBytes: 0,
            maximumStandardOutputBytes: 10,
            maximumRetainedStandardOutputBytes: 4,
            maximumStandardErrorBytes: 1_024
        )

        await assertToolError(.outputLimitExceeded(
            stream: .standardOutput, maximumBytes: 10
        )) {
            _ = try await runner.run(command) { _, _ in }
        }
    }

    func testTimeoutEscalatesAndReapsIsolatedProcessGroup() async throws {
        let runner = ToolProcessRunner()
        let pidRecorder = EventRecorder()
        let timedCommand = command(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30 & printf '%d' $!; wait"],
            timeout: 0.1,
            outputLimit: 1_024,
            gracefulTimeout: 0.05
        )

        do {
            _ = try await withDeadline {
                try await runner.run(timedCommand) { stream, data in
                    pidRecorder.append(stream: stream, data: data)
                }
            }
            XCTFail("Expected timeout")
        } catch let error as ToolExecutionError {
            XCTAssertEqual(error, .timedOut(seconds: 0.1))
        }

        let bytes = pidRecorder.snapshot()
            .filter { $0.stream == .standardOutput }
            .reduce(into: Data()) { $0.append($1.data) }
        if let pid = Int32(String(decoding: bytes, as: UTF8.self)), pid > 1 {
            XCTAssertEqual(Darwin.kill(pid, 0), -1, "descendant survived process-group teardown")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testTaskCancellationAndCancelAllWaitForTeardown() async throws {
        let runner = ToolProcessRunner()
        let blockingCommand = command(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30"],
            timeout: 10,
            gracefulTimeout: 0.05
        )
        let task = Task { try await runner.run(blockingCommand) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await assertToolError(.cancelled) {
            _ = try await withDeadline { try await task.value }
        }

        let first = try await runner.start(blockingCommand)
        let second = try await runner.start(blockingCommand)
        try await withDeadline { await runner.cancelAll() }
        await assertToolError(.cancelled) { _ = try await first.waitForExit() }
        await assertToolError(.cancelled) { _ = try await second.waitForExit() }
    }

    func testWaitForExitIsRepeatableAndOneCancelledWaiterDoesNotStopSession() async throws {
        let runner = ToolProcessRunner()
        let session = try await runner.start(command(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 0.15; printf done"],
            timeout: 2,
            outputLimit: 1_024
        ))
        let cancelledWaiter = Task { try await session.waitForExit() }
        cancelledWaiter.cancel()
        do {
            _ = try await withDeadline { try await cancelledWaiter.value }
            XCTFail("Expected waiter cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let firstWaiter = Task { try await session.waitForExit() }
        let secondWaiter = Task { try await session.waitForExit() }
        let (first, second) = try await withDeadline {
            try await (firstWaiter.value, secondWaiter.value)
        }
        let afterExit = try await session.waitForExit()
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, afterExit)
        XCTAssertEqual(afterExit.stdout, "done")
    }

    func testBoundedAdmissionQueueRejectsOverflowAndCancelledWaiterNeverLaunches() async throws {
        let runner = ToolProcessRunner(
            maximumConcurrentProcesses: 1,
            maximumPendingProcesses: 1
        )
        let blocking = command(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            timeout: 10,
            gracefulTimeout: 0.05
        )
        let first = try await runner.start(blocking)
        let waiting = Task { try await runner.start(blocking) }
        try await Task.sleep(nanoseconds: 30_000_000)

        do {
            _ = try await runner.start(blocking)
            XCTFail("Expected bounded process queue rejection")
        } catch let error as ToolProcessRunnerError {
            XCTAssertEqual(error, .processQueueOverflow(maximumPending: 1))
        }

        waiting.cancel()
        do {
            _ = try await withDeadline { try await waiting.value }
            XCTFail("Expected pending admission cancellation")
        } catch let error as ToolExecutionError {
            XCTAssertEqual(error, .cancelled)
        }
        first.cancel()
        _ = try? await withDeadline { try await first.waitForExit() }
    }

    func testSlowCallbackTriggersBoundedDeliveryOverflow() async throws {
        let runner = ToolProcessRunner(
            maximumPendingOutputDeliveryBytes: 4,
            maximumPendingOutputDeliveryChunks: 1
        )
        do {
            _ = try await withDeadline {
                try await runner.run(self.command(
                    executable: "/bin/sh",
                    arguments: ["-c", "printf 12345678"],
                    outputLimit: 1_024
                )) { _, _ in }
            }
            XCTFail("Expected output delivery overflow")
        } catch let error as ToolProcessRunnerError {
            XCTAssertEqual(error, .outputDeliveryQueueOverflow(
                maximumBytes: 4,
                maximumChunks: 1
            ))
        }
    }

    func testPseudoTerminalProvidesTTYAndInitialWindowSize() async throws {
        let runner = PseudoTerminalProcessRunner()
        let size = try PseudoTerminalSize(columns: 97, rows: 31)
        let session = try await withDeadline {
            try await runner.start(
                self.command(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        "test -t 0 && test -t 1 && test -t 2 && /bin/stty size"
                    ],
                    outputLimit: 1_024
                ),
                size: size
            )
        }
        let result = try await withDeadline { try await session.waitForExit() }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("31 97"))
        XCTAssertEqual(result.standardError, Data())
    }

    func testPseudoTerminalWritesEmptyReturnAndMergesOutput() async throws {
        let runner = PseudoTerminalProcessRunner()
        let recorder = EventRecorder()
        let ready = XCTestExpectation(description: "PTY command is reading")
        let session = try await withDeadline {
            try await runner.start(self.command(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf READY; IFS= read -r line; printf '<%s>' \"$line\"; "
                        + "printf ERR >&2"
                ],
                outputLimit: 2_048
            )) { stream, data in
                recorder.append(stream: stream, data: data)
                if recorder.claimFirstStandardOutput("READY") { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 2)

        try await session.write(Data("\n".utf8))
        let result = try await withDeadline { try await session.waitForExit() }
        let events = recorder.snapshot()

        XCTAssertTrue(events.allSatisfy { $0.stream == .standardOutput })
        XCTAssertTrue(result.stdout.contains("<>"))
        XCTAssertTrue(result.stdout.contains("ERR"))
        XCTAssertEqual(result.standardError, Data())
    }

    func testPseudoTerminalInterruptTargetsForegroundLineDiscipline() async throws {
        let runner = PseudoTerminalProcessRunner()
        let recorder = EventRecorder()
        let ready = XCTestExpectation(description: "PTY foreground command is running")
        let session = try await withDeadline {
            try await runner.start(self.command(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap 'printf INTERRUPTED; exit 42' INT; "
                        + "printf READY; while :; do sleep 30; done"
                ],
                timeout: 5, outputLimit: 2_048
            )) { _, data in
                recorder.append(stream: .standardOutput, data: data)
                if recorder.claimFirstStandardOutput("READY") { ready.fulfill() }
            }
        }
        defer { session.cancel() }
        await fulfillment(of: [ready], timeout: 2)

        try await session.interrupt()
        let result = try await withDeadline { try await session.waitForExit() }

        XCTAssertEqual(result.exitCode, 42)
        XCTAssertTrue(result.stdout.contains("INTERRUPTED"))
    }

    func testPseudoTerminalResizeUpdatesKernelWindowSize() async throws {
        let runner = PseudoTerminalProcessRunner()
        let recorder = EventRecorder()
        let ready = XCTestExpectation(description: "PTY resize command is ready")
        let session = try await withDeadline {
            try await runner.start(self.command(
                executable: "/bin/sh",
                arguments: ["-c", "printf READY; IFS= read -r line; /bin/stty size"],
                timeout: 5, outputLimit: 2_048
            )) { _, data in
                recorder.append(stream: .standardOutput, data: data)
                if recorder.claimFirstStandardOutput("READY") { ready.fulfill() }
            }
        }
        await fulfillment(of: [ready], timeout: 2)

        try await session.resize(to: PseudoTerminalSize(columns: 132, rows: 47))
        try await session.write(Data("\n".utf8))
        let result = try await withDeadline { try await session.waitForExit() }

        XCTAssertTrue(result.stdout.contains("47 132"))
    }

    func testPseudoTerminalRejectsOneShotInputAndCancellationJoinsSession() async throws {
        let runner = PseudoTerminalProcessRunner()
        do {
            _ = try await runner.start(command(
                executable: "/bin/sh", arguments: ["-c", "cat"],
                standardInput: Data("unexpected".utf8), inputLimit: 100
            ))
            XCTFail("Expected PTY one-shot stdin rejection")
        } catch let error as ToolProcessRunnerError {
            XCTAssertEqual(error, .invalidCommand)
        }

        let session = try await runner.start(command(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30 & wait"],
            timeout: 10, gracefulTimeout: 0.05
        ))
        session.cancel()
        await assertToolError(.cancelled) {
            _ = try await withDeadline { try await session.waitForExit() }
        }
    }

    func testPseudoTerminalReportsExecFailureBeforePublishingSession() async throws {
        let runner = PseudoTerminalProcessRunner()
        do {
            _ = try await runner.start(command(
                executable: "/tmp/lumen-missing-" + UUID().uuidString
            ))
            XCTFail("Expected PTY launch failure")
        } catch let error as ToolProcessRunnerError {
            guard case let .launchFailed(detail) = error else {
                return XCTFail("Unexpected PTY runner error: \(error)")
            }
            XCTAssertTrue(detail.contains("exec terminal shell"))
            XCTAssertTrue(detail.contains("errno"))
        }
    }

    func testPseudoTerminalOutputLimitTerminatesSession() async throws {
        let runner = PseudoTerminalProcessRunner()
        do {
            let session = try await runner.start(command(
                executable: "/bin/sh",
                arguments: [
                    "-c", "head -c 4096 /dev/zero | tr '\\0' x; exec sleep 30"
                ],
                timeout: 5, outputLimit: 1_024, gracefulTimeout: 0.05
            ))
            _ = try await withDeadline { try await session.waitForExit() }
            XCTFail("Expected PTY output limit")
        } catch let error as ToolExecutionError {
            XCTAssertEqual(error, .outputLimitExceeded(
                stream: .standardOutput, maximumBytes: 1_024
            ))
        }
    }

    func testPseudoTerminalWritesPreserveAcceptedOrder() async throws {
        let runner = PseudoTerminalProcessRunner(maximumQueuedInputBytes: 1_024)
        let session = try await runner.start(command(
            executable: "/bin/sh",
            arguments: ["-c", "IFS= read -r first; IFS= read -r second; printf '%s|%s' \"$first\" \"$second\""],
            timeout: 5, outputLimit: 2_048
        ))

        try await session.write(Data("first\n".utf8))
        try await session.write(Data("second\n".utf8))
        let result = try await withDeadline { try await session.waitForExit() }

        XCTAssertTrue(result.stdout.contains("first|second"))
    }

    func testPseudoTerminalRejectsOversizedAndOverflowingInput() async throws {
        let runner = PseudoTerminalProcessRunner(maximumQueuedInputBytes: 16)
        let session = try await runner.start(command(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 1; cat >/dev/null"],
            timeout: 3
        ))
        defer { session.cancel() }

        do {
            try await session.write(Data(
                repeating: 0x61,
                count: ToolExecutionLimits.maximumStdinWriteBytes + 1
            ))
            XCTFail("Expected PTY per-write rejection")
        } catch let error as ToolProcessSessionError {
            XCTAssertEqual(error, .writeTooLarge(
                actualBytes: ToolExecutionLimits.maximumStdinWriteBytes + 1,
                maximumBytes: ToolExecutionLimits.maximumStdinWriteBytes
            ))
        }

        do {
            try await session.write(Data(repeating: 0x61, count: 17))
            XCTFail("Expected PTY queue overflow")
        } catch let error as ToolProcessSessionError {
            XCTAssertEqual(error, .queueOverflow(maximumBytes: 16))
        }
    }

    private func command(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval = 2,
        inputLimit: Int = ToolExecutionLimits.maximumOneShotStdinBytes,
        outputLimit: Int = 2 * ToolExecutionLimits.maximumOutputChunkBytes,
        errorLimit: Int = 64 * 1_024,
        gracefulTimeout: TimeInterval = 0.1,
        processGroupPolicy: ToolProcessGroupPolicy = .isolated
    ) -> ToolCommand {
        ToolCommand(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            workingDirectoryURL: root,
            environment: environment,
            standardInput: standardInput,
            timeout: timeout,
            maximumStandardInputBytes: inputLimit,
            maximumStandardOutputBytes: outputLimit,
            maximumStandardErrorBytes: errorLimit,
            gracefulTerminationTimeout: gracefulTimeout,
            processGroupPolicy: processGroupPolicy
        )
    }

    private func withDeadline<T: Sendable>(
        seconds: TimeInterval = 3,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let gate = DeadlineGate<T>(continuation: continuation)
            Task {
                do { await gate.finish(.success(try await operation())) }
                catch { await gate.finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000)
                )
                await gate.finish(.failure(TestDeadlineError.elapsed))
            }
        }
    }

    private func assertToolError(
        _ expected: ToolExecutionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as ToolExecutionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private enum TestDeadlineError: Error {
    case elapsed
}

private final class SendableExpectation: @unchecked Sendable {
    let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() { expectation.fulfill() }
}

private actor DeadlineGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?

    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

private final class EventRecorder: @unchecked Sendable {
    struct Event {
        let stream: ToolOutputStream
        let data: Data
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var claimedStandardOutputBytes: Set<UInt8> = []
    private var claimedStandardOutputTexts: Set<String> = []

    func append(stream: ToolOutputStream, data: Data) {
        lock.lock()
        events.append(Event(stream: stream, data: data))
        lock.unlock()
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func claimFirstStandardOutputByte(_ byte: UInt8) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimedStandardOutputBytes.contains(byte),
              events.contains(where: {
                  $0.stream == .standardOutput && $0.data.contains(byte)
              }) else { return false }
        claimedStandardOutputBytes.insert(byte)
        return true
    }

    func claimFirstStandardOutput(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimedStandardOutputTexts.contains(text) else { return false }
        let output = events
            .filter { $0.stream == .standardOutput }
            .reduce(into: Data()) { $0.append($1.data) }
        guard output.range(of: Data(text.utf8)) != nil else { return false }
        claimedStandardOutputTexts.insert(text)
        return true
    }
}
