import Foundation
import PhoneUseKit
import Security

/// Local login Keychain, with a separate item for each discovery identity. The comment on the
/// same item reserves an attempt across app restarts and clients if delivery is interrupted.
struct UnlockCredential {
    let deviceID: String
    private static let noPasscode = "no device passcode"
    private static let pending = "pending device verification"

    private static let serviceQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cn.andysheng.phoneuse.device-unlock",
        kSecAttrSynchronizable as String: false,
    ]

    private var query: [String: Any] {
        var query = Self.serviceQuery
        query[kSecAttrAccount as String] = deviceID
        return query
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw DeviceHubError.serviceFailed("无法访问本机钥匙串（\(status)）。")
        }
    }

    enum Setting {
        case pin(String), noPasscode, remove
    }

    func apply(_ setting: Setting) throws {
        switch setting {
        case .pin(let pin): try save(pin)
        case .noPasscode: try write(data: Data(), comment: Self.noPasscode)
        case .remove: try remove()
        }
    }

    func save(_ pin: String) throws {
        guard DeviceSession.validUnlockPIN(pin) else { throw DeviceHubError.serviceFailed("请输入 4 位或 6 位数字密码。") }
        try write(data: Data(pin.utf8), comment: "")
    }

    private func write(data: Data, comment: String) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrComment as String: comment]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(values) { _, new in new }
            item[kSecAttrLabel as String] = "PhoneUse 设备解锁"
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else { try Self.check(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try Self.check(status) }
    }

    enum Status: String {
        case missing = "未保存密码"
        case noPasscode = "已设为无锁屏密码"
        case saved = "已保存密码"
        case pending = "上次输入未确认，请核对后重新保存密码。"

        var hasPIN: Bool { self == .saved || self == .pending }

        func requiresConfiguration(isSimulator: Bool) -> Bool {
            self == .missing && !isSimulator
        }
    }

    /// List metadata only; displaying badges never requests the PIN data.
    static func savedStatuses() throws -> [String: Status] {
        var lookup = serviceQuery
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        try check(status)
        var statuses = [String: Status]()
        for attributes in result as? [[String: Any]] ?? [] {
            if let account = attributes[kSecAttrAccount as String] as? String {
                switch attributes[kSecAttrComment as String] as? String {
                case pending: statuses[account] = .pending
                case noPasscode: statuses[account] = .noPasscode
                default: statuses[account] = .saved
                }
            }
        }
        return statuses
    }

    private func savedItem() throws -> [String: Any]? {
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try Self.check(status)
        guard let item = value as? [String: Any] else { throw DeviceHubError.serviceFailed("请重新保存设备密码。") }
        return item
    }

    private func decodedPIN(_ item: [String: Any]) throws -> String {
        guard let data = item[kSecValueData as String] as? Data, let pin = String(data: data, encoding: .utf8),
              DeviceSession.validUnlockPIN(pin) else { throw DeviceHubError.serviceFailed("请重新保存设备密码。") }
        return pin
    }

    func savedPIN() throws -> String? {
        guard let item = try savedItem(), item[kSecAttrComment as String] as? String != Self.noPasscode else { return nil }
        return try decodedPIN(item)
    }

    func reserve() throws -> String? {
        guard let item = try savedItem(), item[kSecAttrComment as String] as? String != Self.noPasscode else { return nil }
        guard item[kSecAttrComment as String] as? String != Self.pending else {
            throw DeviceHubError.serviceFailed("上次密码输入未确认。请在 PhoneUse 设备设置中核对并重新保存密码。")
        }
        let pin = try decodedPIN(item)
        // Including the previous comment in the match makes claiming the item atomic even
        // if two signed copies of PhoneUse are running in different processes.
        var available = query
        available[kSecAttrComment as String] = ""
        try Self.check(SecItemUpdate(available as CFDictionary, [kSecAttrComment: Self.pending] as CFDictionary))
        return pin
    }

    func setPending(_ pending: Bool) throws {
        var match = query
        match[kSecAttrComment as String] = pending ? "" : Self.pending
        let status = SecItemUpdate(match as CFDictionary, [kSecAttrComment: pending ? Self.pending : ""] as CFDictionary)
        if status != errSecItemNotFound { try Self.check(status) }
    }
}

actor DeviceUnlockController {
    static let shared = DeviceUnlockController()
    private var active = Set<String>()
    private var reserved = [String: String]()

    func statuses(for devices: [DeviceSummary]) async throws -> [String: UnlockCredential.Status] {
        let saved = try UnlockCredential.savedStatuses()
        var result = [String: UnlockCredential.Status]()
        for device in devices {
            try Task.checkCancellation()
            if !device.isAndroid {
                result[device.id] = saved[device.id] ?? .missing
            } else if !saved.keys.contains(where: { $0.hasPrefix(device.id + ":user:") }) {
                result[device.id] = .missing
            } else if !device.isReady {
                // The device has a saved PIN. Its current user can be verified again when connected.
                if saved.contains(where: { $0.key.hasPrefix(device.id + ":user:") && $0.value.hasPIN }) {
                    result[device.id] = .saved
                }
            } else if let account = try? await device.unlockCredentialID() {
                result[device.id] = saved[account] ?? .missing
            }
        }
        return result
    }

    func configure(_ device: DeviceSummary, setting: UnlockCredential.Setting) async throws {
        guard active.insert(device.id).inserted else { throw DeviceHubError.serviceFailed("设备正在解锁。") }
        defer { active.remove(device.id) }
        let item = try await UnlockCredential(deviceID: device.unlockCredentialID())
        try item.apply(setting)
    }

    private func reserve(_ credentialID: String, device: String) throws -> String? {
        let pin = try UnlockCredential(deviceID: credentialID).reserve()
        if pin != nil { reserved[device] = credentialID }
        return pin
    }

    func unlock(_ device: DeviceSummary, requireConfiguration: Bool = false) async throws -> DeviceUnlockResult {
        let id = device.id
        guard active.insert(id).inserted else { throw DeviceHubError.serviceFailed("设备正在解锁。") }
        defer {
            active.remove(id)
            reserved.removeValue(forKey: id)
        }
        if requireConfiguration {
            guard let status = try await statuses(for: [device])[id] else {
                throw DeviceHubError.serviceFailed("无法读取当前设备用户的密码状态，请重新连接后再试。")
            }
            if status.requiresConfiguration(isSimulator: device.isSimulator) { return .needsPasscode }
            if status == .pending { throw DeviceHubError.serviceFailed(status.rawValue) }
        }
        try Task.checkCancellation()
        let session = try await DeviceHub.shared.session(for: id)
        let result: DeviceUnlockResult
        do { result = try await session.unlock { try await self.reserve($0, device: id) } }
        catch {
            if reserved[id] != nil { return .unconfirmed }
            throw error
        }
        // These results are verified success or a stop before any PIN tap.
        if [.unlocked, .alreadyUnlocked, .needsUserUnlock].contains(result), let credentialID = reserved[id] {
            try UnlockCredential(deviceID: credentialID).setPending(false)
        }
        return result
    }
}
