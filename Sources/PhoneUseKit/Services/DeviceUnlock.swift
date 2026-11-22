import Foundation

public enum DeviceUnlockResult: String, Sendable {
    case unlocked, alreadyUnlocked = "already_unlocked"
    case noPasscodeRequired = "no_passcode_required"
    case needsUserUnlock = "needs_user_unlock"
    case needsPasscode = "needs_saved_pin"
    case unconfirmed = "unlock_unconfirmed"
}

public struct DeviceLockStatus: Sendable {
    public enum State: String, Sendable { case locked, unlocked, unknown }
    public let state: State
    public let passcodeRequired: Bool?
    public let unlockedSinceBoot: Bool?

    public init(_ state: State, passcodeRequired: Bool? = nil, unlockedSinceBoot: Bool? = nil) {
        self.state = state
        self.passcodeRequired = passcodeRequired
        self.unlockedSinceBoot = unlockedSinceBoot
    }

    init(physicalInfo: [String: Any]) {
        let required = physicalInfo["passcodeRequired"] as? Bool
        let sinceBoot = physicalInfo["unlockedSinceBoot"] as? Bool
        self.init(required == true || sinceBoot == false ? .locked : .unknown,
                  passcodeRequired: required, unlockedSinceBoot: sinceBoot)
    }
}

extension DeviceSummary {
    func physicalLockStatus() async throws -> DeviceLockStatus {
        let info = try await DeviceCtl.run(["device", "info", "lockState", "--device", deviceIdentifier], timeout: 5)
        return DeviceLockStatus(physicalInfo: info)
    }

    func simulatorScreenLocked() async throws -> Bool {
        guard let developer = SimulatorTools.developerDirectory() else {
            throw DeviceHubError.capabilityUnavailable("Xcode simulator tools")
        }
        let name = "com.apple.springboard.lockstate"
        let output = try await SimulatorTools.simctl(["spawn", deviceIdentifier, "notifyutil", "-g", name],
                                                    developerDirectory: developer, timeout: .seconds(5))
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[0] == Substring(name), let value = UInt64(fields[1]) else {
            throw DeviceHubError.serviceFailed("Cannot read the simulator lock state")
        }
        return value != 0
    }
}

/// Only the app owns credentials. Obtain the PIN before locating the keypad so Keychain latency cannot stale the coordinates.
extension DeviceSession {
    public func unlock(takePIN: @Sendable (String) async throws -> String?) async throws -> DeviceUnlockResult {
        if device.isAndroid { return try await unlockAndroid(takePIN: takePIN) }
        if device.isSimulator { return try await unlockSimulator { try await takePIN(self.device.id) } }
        return try await unlockPhone { try await takePIN(self.device.id) }
    }

    private func unlockSimulator(takePIN: @Sendable () async throws -> String?) async throws -> DeviceUnlockResult {
        func isLocked() async throws -> Bool { try await device.simulatorScreenLocked() }
        guard try await isLocked() else { return .alreadyUnlocked }
        try await press(.home)
        try await Task.sleep(for: .milliseconds(650))
        if try await isLocked() {
            try await swipe(fromX: 0.5, fromY: 0.99, toX: 0.5, toY: 0.28)
        }
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(250))
            if try await !isLocked() { return .unlocked }
        }
        return try await PasscodeKeypad.unlock(isLocked: isLocked, locate: waitForKeypad, takePIN: takePIN, tap: tapPasscodeKey)
    }

    private func unlockPhone(takePIN: @Sendable () async throws -> String?) async throws -> DeviceUnlockResult {
        func state() async throws -> (requiresPIN: Bool, firstUnlock: Bool) {
            let status = try await device.physicalLockStatus()
            guard let required = status.passcodeRequired, let sinceBoot = status.unlockedSinceBoot else {
                throw DeviceHubError.serviceFailed("Cannot determine the device passcode state")
            }
            return (required, sinceBoot)
        }
        let initial = try await state()
        guard initial.firstUnlock else { return .needsUserUnlock }
        if !initial.requiresPIN {
            guard let screenState = try await physicalScreenLock() else { return .noPasscodeRequired }
            guard screenState else { return .alreadyUnlocked }
        }
        func isLocked() async throws -> Bool {
            if try await state().requiresPIN { return true }
            return try await physicalScreenLock() ?? false
        }
        func presentKeypad() async throws -> PasscodeKeypad? {
            // Load Vision before waking, then use separate Home presses for wake and unlock.
            if let pad = try? await visibleKeypad() { return pad }
            for delay in [Duration.milliseconds(950), .seconds(1)] {
                guard try await isLocked() else { return nil }
                try await press(.home)
                try await Task.sleep(for: delay)
                if let pad = try await visibleKeypad() { return pad }
            }
            guard try await isLocked() else { return nil }
            try await swipe(fromX: 0.5, fromY: 0.96, toX: 0.5, toY: 0.22, duration: .milliseconds(220))
            try await Task.sleep(for: .milliseconds(650))
            return try await waitForKeypad()
        }
        if !initial.requiresPIN {
            _ = try await presentKeypad()
            guard try await isLocked() else { return .unlocked }
            guard try await state().requiresPIN else { return .needsUserUnlock }
        }
        let result = try await PasscodeKeypad.unlock(isLocked: { try await state().requiresPIN },
            locate: presentKeypad, takePIN: takePIN, tap: tapPasscodeKey)
        if result == .unlocked, try await physicalScreenLock() == true { return .unconfirmed }
        return result
    }

    private func visibleKeypad() async throws -> PasscodeKeypad? {
        let image = try await screenshot(replyTimeout: .seconds(3))
        // Physical HID uses native portrait coordinates. Stop if a rotated capture has a
        // different aspect; the simulator adapter already maps its displayed orientation.
        if !device.isSimulator {
            let aspect = Double(image.width) / Double(image.height)
            guard abs(aspect - display.pixelWidth / display.pixelHeight) < 0.01 else { return nil }
        }
        return try PasscodeKeypad.read(image)
    }

    private func waitForKeypad() async throws -> PasscodeKeypad? {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            if let pad = try await visibleKeypad() { return pad }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        return nil
    }

    public static func validUnlockPIN(_ pin: String) -> Bool {
        [4, 6].contains(pin.utf8.count) && pin.utf8.allSatisfy { (48...57).contains($0) }
    }
}
