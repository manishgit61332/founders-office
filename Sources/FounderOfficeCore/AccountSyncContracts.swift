import Foundation

/// Strong UUID wrappers prevent product accounts, workspaces, devices, and
/// optional connector accounts from being used interchangeably.
public protocol FounderOfficeUUIDIdentifier: Codable, Hashable, Sendable {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension FounderOfficeUUIDIdentifier {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct FounderAccountID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct WorkspaceID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct DeviceID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct SyncOperationID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct ActivityEventID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Connector accounts are separately authorized resources. They are never a
/// Founder account, an authentication session, or a workspace tenancy key.
public struct ConnectorAccountID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum AccountIdentityProvider: String, Codable, CaseIterable, Sendable {
    case google
    case apple
}

/// Opaque identifiers associated with an already authenticated Supabase
/// session. Tokens and refresh credentials intentionally do not belong here.
public struct AuthSession: Codable, Equatable, Sendable {
    public let accountID: FounderAccountID
    public let workspaceID: WorkspaceID
    public let deviceID: DeviceID
    public let identityProvider: AccountIdentityProvider

    public init(
        accountID: FounderAccountID,
        workspaceID: WorkspaceID,
        deviceID: DeviceID,
        identityProvider: AccountIdentityProvider
    ) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.identityProvider = identityProvider
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case workspaceID = "workspaceId"
        case deviceID = "deviceId"
        case identityProvider
    }
}

public struct FounderProfile: Codable, Equatable, Sendable {
    public let accountID: FounderAccountID
    public let identityProvider: AccountIdentityProvider
    public let displayName: String?

    public init(
        accountID: FounderAccountID,
        identityProvider: AccountIdentityProvider,
        displayName: String?
    ) throws {
        self.accountID = accountID
        self.identityProvider = identityProvider
        self.displayName = try FounderDisplayName.normalize(displayName)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(FounderAccountID.self, forKey: .accountID)
        identityProvider = try container.decode(AccountIdentityProvider.self, forKey: .identityProvider)
        let serverName = try container.decodeIfPresent(String.self, forKey: .displayName)
        let normalized = try FounderDisplayName.normalize(serverName)
        let serverNameIsCanonical: Bool
        switch (serverName, normalized) {
        case (nil, nil):
            serverNameIsCanonical = true
        case let (.some(serverName), .some(normalized)):
            serverNameIsCanonical = serverName.utf8.elementsEqual(normalized.utf8)
        default:
            serverNameIsCanonical = false
        }
        guard serverNameIsCanonical else {
            throw SyncContractValidationError.invalidDisplayName
        }
        displayName = normalized
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case identityProvider
        case displayName
    }
}

public enum FounderDisplayName {
    public static let maximumUnicodeScalarCount = 80
    public static let maximumUTF8ByteCount = 320

    public static func normalize(_ candidate: String?) throws -> String? {
        guard let candidate else { return nil }
        let nfcCandidate = candidate.precomposedStringWithCanonicalMapping
        guard !nfcCandidate.unicodeScalars.contains(where: isForbiddenScalar) else {
            throw SyncContractValidationError.invalidDisplayName
        }
        let normalized = nfcCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.contains(where: isVisibleScalar),
              normalized.unicodeScalars.count <= maximumUnicodeScalarCount,
              normalized.utf8.count <= maximumUTF8ByteCount else {
            throw SyncContractValidationError.invalidDisplayName
        }
        return normalized
    }

    private static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true
        default:
            break
        }

        return scalar.value == 0x061C
            || scalar.value == 0x200E
            || scalar.value == 0x200F
            || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
            || scalar.value == 0xFEFF
    }

    private static func isVisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}

public struct SyncCursor: Codable, Comparable, Hashable, Sendable {
    public let value: Int64

    public init(value: Int64) throws {
        guard value >= 0 else { throw SyncContractValidationError.negativeCursor }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(value: container.decode(Int64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case workspace
    case move
    case appearance
    case primaryGoal
    case milestone
    case asset
}

public enum SyncMutationAction: String, Codable, Sendable {
    case upsert
    case delete
}

/// A language-neutral JSON value that preserves signed 64-bit integers and
/// exact base-10 decimals without coercing them through binary floating-point.
public indirect enum SyncJSONValue: Codable, Equatable, Sendable {
    case object([String: SyncJSONValue])
    case array([SyncJSONValue])
    case string(String)
    case integer(Int64)
    case number(Decimal)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SyncJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SyncJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum SyncContractValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case negativeRevision
    case negativeCursor
    case invalidChangedFields
    case fieldClockMismatch
    case payloadMismatch
    case futureClockSkew
    case invalidDisplayName
    case invalidResponse
    case invalidOperationResult
    case invalidActivityEvent
    case invalidAssetTransfer
    case invalidPayload
    case invalidRecord
}

private enum SyncContractRules {
    static let maximumAssetByteSize: Int64 = 5_242_880
    static let maximumAppearanceByteSize = 262_144

    static func allowedFields(for entityType: SyncEntityType) -> Set<String> {
        switch entityType {
        case .workspace:
            return ["name"]
        case .move:
            return [
                "title", "details", "status", "previousStatus", "priority", "dueOn",
                "completedAt", "deletedAt", "source", "createdAt",
            ]
        case .appearance:
            return ["schemaVersion", "preferences", "deletedAt"]
        case .primaryGoal:
            return [
                "title", "metric", "currentValue", "targetValue", "unit", "dueOn",
                "deletedAt",
            ]
        case .milestone:
            return ["title", "dueAt", "deletedAt", "createdAt"]
        case .asset:
            return ["kind", "storagePath", "contentType", "byteSize", "sha256", "deletedAt"]
        }
    }

    static func requiredCreateFields(for entityType: SyncEntityType) -> Set<String> {
        switch entityType {
        case .workspace:
            return []
        case .move:
            return ["title", "details", "status", "priority", "source", "createdAt"]
        case .appearance:
            return ["schemaVersion", "preferences"]
        case .primaryGoal:
            return ["title", "metric", "unit", "dueOn"]
        case .milestone:
            return ["title", "dueAt", "createdAt"]
        case .asset:
            return ["kind", "storagePath", "contentType", "byteSize", "sha256"]
        }
    }

    static func isValidFieldName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first,
              (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    static func validatePayload(
        _ payload: [String: SyncJSONValue],
        entityType: SyncEntityType,
        entityID: UUID,
        baseRevision: Int64,
        changedFields: Set<String>,
        workspaceID: WorkspaceID? = nil
    ) throws {
        guard payload.values.allSatisfy({ isValidJSON($0, depth: 0) }) else {
            throw SyncContractValidationError.invalidPayload
        }
        if baseRevision == 0,
           !requiredCreateFields(for: entityType).isSubset(of: changedFields) {
            throw SyncContractValidationError.invalidPayload
        }
        if baseRevision > 0, changedFields.contains("createdAt") {
            throw SyncContractValidationError.invalidPayload
        }

        for field in changedFields {
            guard let value = payload[field], validateField(
                field,
                value: value,
                entityType: entityType,
                entityID: entityID,
                workspaceID: workspaceID
            ) else {
                throw SyncContractValidationError.invalidPayload
            }
        }
    }

    static func validateRecord(
        _ record: [String: SyncJSONValue],
        entityType: SyncEntityType,
        entityID: UUID,
        expectedRevision: Int64? = nil,
        workspaceID: WorkspaceID? = nil,
        requiredClockFields: Set<String> = []
    ) throws {
        let sharedRequired: Set<String> = ["id", "revision", "fieldClocks", "createdAt", "updatedAt"]
        let required: Set<String>
        let optional: Set<String>
        switch entityType {
        case .workspace:
            required = sharedRequired.union(["name"])
            optional = []
        case .move:
            required = sharedRequired.union(["title", "details", "status", "priority", "source"])
            optional = ["previousStatus", "dueOn", "completedAt", "deletedAt"]
        case .appearance:
            required = sharedRequired.union(["schemaVersion", "preferences"])
            optional = ["deletedAt"]
        case .primaryGoal:
            required = sharedRequired.union(["title", "metric", "unit", "dueOn"])
            optional = ["currentValue", "targetValue", "deletedAt"]
        case .milestone:
            required = sharedRequired.union(["title", "dueAt"])
            optional = ["deletedAt"]
        case .asset:
            required = sharedRequired.union(["kind", "storagePath", "contentType", "byteSize", "sha256"])
            optional = ["deletedAt"]
        }

        let keys = Set(record.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)),
              case let .string(idString)? = record["id"],
              UUID(uuidString: idString) == entityID,
              let revision = integer(record["revision"]), revision > 0,
              expectedRevision.map({ $0 == revision }) ?? true,
              case let .object(fieldClocks)? = record["fieldClocks"],
              (1...32).contains(fieldClocks.count),
              Set(fieldClocks.keys).isSubset(of: allowedFields(for: entityType)),
              requiredClockFields.isSubset(of: Set(fieldClocks.keys)),
              fieldClocks.allSatisfy({
                  isValidFieldName($0.key) && isTimestamp($0.value)
              }),
              isTimestamp(record["createdAt"]),
              isTimestamp(record["updatedAt"]) else {
            throw SyncContractValidationError.invalidRecord
        }

        let entityFields = keys.subtracting(sharedRequired)
        for field in entityFields {
            guard let value = record[field], validateField(
                field,
                value: value,
                entityType: entityType,
                entityID: entityID,
                workspaceID: workspaceID
            ) else {
                throw SyncContractValidationError.invalidRecord
            }
        }
    }

    static func canonicalAssetPath(
        workspaceID: WorkspaceID,
        assetID: UUID
    ) -> String {
        "workspaces/\(workspaceID.rawValue.uuidString.lowercased())/vision-images/\(assetID.uuidString.lowercased()).jpg"
    }

    static func isCanonicalAssetPath(
        _ path: String,
        assetID: UUID,
        workspaceID: WorkspaceID? = nil
    ) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "workspaces",
              components[2] == "vision-images",
              let pathWorkspaceID = UUID(uuidString: String(components[1])),
              String(components[1]) == pathWorkspaceID.uuidString.lowercased(),
              components[3].hasSuffix(".jpg") else { return false }
        let assetComponent = components[3].dropLast(4)
        guard let pathAssetID = UUID(uuidString: String(assetComponent)),
              String(assetComponent) == pathAssetID.uuidString.lowercased(),
              pathAssetID == assetID else { return false }
        return workspaceID.map { $0.rawValue == pathWorkspaceID } ?? true
    }

    static func isCanonicalDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (48...57).contains(byte)
              }),
              let year = Int(value.prefix(4)), year >= 1,
              let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    static func isFiniteTimestamp(_ value: Date) -> Bool {
        value.timeIntervalSinceReferenceDate.isFinite
    }

    static func recordID(_ record: [String: SyncJSONValue]) -> UUID? {
        guard case let .string(value)? = record["id"] else { return nil }
        return UUID(uuidString: value)
    }

    static func stringValue(_ value: SyncJSONValue?) -> String? {
        guard case let .string(string)? = value else { return nil }
        return string
    }

    static func integerValue(_ value: SyncJSONValue?) -> Int64? {
        integer(value)
    }

    static func timestampValue(_ value: SyncJSONValue?) -> Date? {
        guard let string = stringValue(value) else { return nil }
        return timestamp(string)
    }

    private static func validateField(
        _ field: String,
        value: SyncJSONValue,
        entityType: SyncEntityType,
        entityID: UUID,
        workspaceID: WorkspaceID?
    ) -> Bool {
        switch entityType {
        case .workspace:
            return field == "name" && isBoundedNonemptyString(value, maximum: 120)
        case .move:
            switch field {
            case "title": return isBoundedNonemptyString(value, maximum: 500)
            case "details": return isString(value, maximum: 20_000)
            case "status": return isEnumString(value, values: ["doing", "next", "blocked", "done"])
            case "previousStatus":
                return isNull(value) || isEnumString(value, values: ["doing", "next", "blocked", "done"])
            case "priority": return isEnumString(value, values: ["P0", "P1", "P2", "P3"])
            case "dueOn": return isNull(value) || isDate(value)
            case "completedAt", "deletedAt": return isNull(value) || isTimestamp(value)
            case "source": return isBoundedNonemptyString(value, maximum: 64)
            case "createdAt": return isTimestamp(value)
            default: return false
            }
        case .appearance:
            switch field {
            case "schemaVersion":
                return integer(value).map({ (1...Int64(Int32.max)).contains($0) }) ?? false
            case "preferences":
                guard case .object = value,
                      let data = try? JSONEncoder().encode(value) else { return false }
                return data.count <= maximumAppearanceByteSize
            case "deletedAt": return isNull(value) || isTimestamp(value)
            default: return false
            }
        case .primaryGoal:
            switch field {
            case "title": return isBoundedNonemptyString(value, maximum: 500)
            case "metric": return isString(value, maximum: 120)
            case "currentValue", "targetValue": return isNull(value) || isValidGoalDecimal(value)
            case "unit": return isEnumString(value, values: ["usd", "inr", "number", "percent"])
            case "dueOn": return isDate(value)
            case "deletedAt": return isNull(value) || isTimestamp(value)
            default: return false
            }
        case .milestone:
            switch field {
            case "title": return isBoundedNonemptyString(value, maximum: 500)
            case "dueAt", "createdAt": return isTimestamp(value)
            case "deletedAt": return isNull(value) || isTimestamp(value)
            default: return false
            }
        case .asset:
            switch field {
            case "kind": return isEnumString(value, values: ["visionImage"])
            case "storagePath":
                guard case let .string(path) = value else { return false }
                return isCanonicalAssetPath(path, assetID: entityID, workspaceID: workspaceID)
            case "contentType": return isEnumString(value, values: ["image/jpeg"])
            case "byteSize":
                return integer(value).map({ (1...maximumAssetByteSize).contains($0) }) ?? false
            case "sha256":
                guard case let .string(digest) = value, digest.utf8.count == 64 else { return false }
                return digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            case "deletedAt": return isNull(value) || isTimestamp(value)
            default: return false
            }
        }
    }

    private static func isValidJSON(_ value: SyncJSONValue, depth: Int) -> Bool {
        guard depth <= 64 else { return false }
        switch value {
        case let .object(object):
            return object.count <= 10_000
                && object.values.allSatisfy({ isValidJSON($0, depth: depth + 1) })
        case let .array(array):
            return array.count <= 10_000
                && array.allSatisfy({ isValidJSON($0, depth: depth + 1) })
        case let .number(number):
            return !number.isNaN
        default:
            return true
        }
    }

    private static func isString(_ value: SyncJSONValue, maximum: Int) -> Bool {
        guard case let .string(string) = value else { return false }
        return string.unicodeScalars.count <= maximum
    }

    private static func isBoundedNonemptyString(_ value: SyncJSONValue, maximum: Int) -> Bool {
        guard case let .string(string) = value,
              string.unicodeScalars.count <= maximum else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isEnumString(_ value: SyncJSONValue, values: Set<String>) -> Bool {
        guard case let .string(string) = value else { return false }
        return values.contains(string)
    }

    private static func isNull(_ value: SyncJSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func isDate(_ value: SyncJSONValue) -> Bool {
        guard case let .string(string) = value else { return false }
        return isCanonicalDate(string)
    }

    private static func isTimestamp(_ value: SyncJSONValue?) -> Bool {
        guard case let .string(string)? = value else { return false }
        return timestamp(string) != nil
    }

    private static func timestamp(_ string: String) -> Date? {
        let pattern = #"^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,6})?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#
        guard string.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: string) ?? plain.date(from: string),
              isFiniteTimestamp(date) else { return nil }
        return date
    }

    private static func integer(_ value: SyncJSONValue?) -> Int64? {
        switch value {
        case let .integer(integer):
            return integer
        case let .number(decimal):
            guard !decimal.isNaN else { return nil }
            let converted = NSDecimalNumber(decimal: decimal).int64Value
            return Decimal(converted) == decimal ? converted : nil
        default:
            return nil
        }
    }

    private static func isValidGoalDecimal(_ value: SyncJSONValue) -> Bool {
        let decimal: Decimal
        switch value {
        case let .integer(integer): decimal = Decimal(integer)
        case let .number(number): decimal = number
        default: return false
        }
        return (try? GoalDecimal(validating: decimal)) != nil
    }
}

public struct SyncOperation: Codable, Equatable, Sendable {
    public static let contractVersion = 1
    public static let maximumFutureClockSkew: TimeInterval = 5 * 60

    public let contractVersion: Int
    public let operationID: SyncOperationID
    public let entityType: SyncEntityType
    public let entityID: UUID
    public let action: SyncMutationAction
    public let baseRevision: Int64
    public let changedFields: [String]
    public let fieldClocks: [String: Date]
    public let payload: [String: SyncJSONValue]?
    public let occurredAt: Date

    public init(
        operationID: SyncOperationID,
        entityType: SyncEntityType,
        entityID: UUID,
        action: SyncMutationAction,
        baseRevision: Int64,
        changedFields: [String],
        fieldClocks: [String: Date],
        payload: [String: SyncJSONValue]?,
        occurredAt: Date,
        contractVersion: Int = SyncOperation.contractVersion
    ) throws {
        self.contractVersion = contractVersion
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.action = action
        self.baseRevision = baseRevision
        self.changedFields = changedFields
        self.fieldClocks = fieldClocks
        self.payload = payload
        self.occurredAt = occurredAt
        try validate()
    }

    public func validate() throws {
        guard contractVersion == Self.contractVersion else {
            throw SyncContractValidationError.unsupportedVersion
        }
        guard baseRevision >= 0 else {
            throw SyncContractValidationError.negativeRevision
        }
        guard (1...32).contains(changedFields.count),
              Set(changedFields).count == changedFields.count,
              changedFields.allSatisfy(SyncContractRules.isValidFieldName),
              Set(changedFields).isSubset(of: SyncContractRules.allowedFields(for: entityType)) else {
            throw SyncContractValidationError.invalidChangedFields
        }
        guard Set(fieldClocks.keys) == Set(changedFields),
              fieldClocks.values.allSatisfy(SyncContractRules.isFiniteTimestamp),
              SyncContractRules.isFiniteTimestamp(occurredAt) else {
            throw SyncContractValidationError.fieldClockMismatch
        }

        switch action {
        case .upsert:
            guard let payload, Set(payload.keys) == Set(changedFields) else {
                throw SyncContractValidationError.payloadMismatch
            }
            try SyncContractRules.validatePayload(
                payload,
                entityType: entityType,
                entityID: entityID,
                baseRevision: baseRevision,
                changedFields: Set(changedFields)
            )
        case .delete:
            guard changedFields == ["deletedAt"], payload == nil else {
                throw SyncContractValidationError.payloadMismatch
            }
        }
    }

    /// Applies request-scoped checks that cannot be proven by the operation
    /// envelope alone, including the private asset's workspace path prefix.
    public func validate(for workspaceID: WorkspaceID) throws {
        try validate()
        guard action == .upsert, let payload else { return }
        try SyncContractRules.validatePayload(
            payload,
            entityType: entityType,
            entityID: entityID,
            baseRevision: baseRevision,
            changedFields: Set(changedFields),
            workspaceID: workspaceID
        )
    }

    public func validateClockSkew(relativeTo now: Date) throws {
        let latestAllowed = now.addingTimeInterval(Self.maximumFutureClockSkew)
        guard now.timeIntervalSinceReferenceDate.isFinite,
              occurredAt.timeIntervalSinceReferenceDate.isFinite,
              occurredAt <= latestAllowed,
              fieldClocks.values.allSatisfy({
                  $0.timeIntervalSinceReferenceDate.isFinite && $0 <= latestAllowed
              }) else {
            throw SyncContractValidationError.futureClockSkew
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationID: container.decode(SyncOperationID.self, forKey: .operationID),
            entityType: container.decode(SyncEntityType.self, forKey: .entityType),
            entityID: container.decode(UUID.self, forKey: .entityID),
            action: container.decode(SyncMutationAction.self, forKey: .action),
            baseRevision: container.decode(Int64.self, forKey: .baseRevision),
            changedFields: container.decode([String].self, forKey: .changedFields),
            fieldClocks: container.decode([String: Date].self, forKey: .fieldClocks),
            payload: container.decodeIfPresent(
                [String: SyncJSONValue].self,
                forKey: .payload
            ),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(entityID, forKey: .entityID)
        try container.encode(action, forKey: .action)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(changedFields, forKey: .changedFields)
        try container.encode(fieldClocks, forKey: .fieldClocks)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encode(occurredAt, forKey: .occurredAt)
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case operationID = "operationId"
        case entityType
        case entityID = "entityId"
        case action
        case baseRevision
        case changedFields
        case fieldClocks
        case payload
        case occurredAt
    }
}

public enum SyncConflictReason: String, Codable, Sendable {
    case revisionMismatch
    case overlappingChanges
    case fieldClockLost
    case missingRecord
}

public struct SyncConflict: Codable, Equatable, Sendable {
    public let operationID: SyncOperationID
    public let entityType: SyncEntityType
    public let entityID: UUID
    public let baseRevision: Int64
    public let currentRevision: Int64
    public let reason: SyncConflictReason
    public let conflictingFields: [String]
    public let serverRecord: [String: SyncJSONValue]?

    public init(
        operationID: SyncOperationID,
        entityType: SyncEntityType,
        entityID: UUID,
        baseRevision: Int64,
        currentRevision: Int64,
        reason: SyncConflictReason,
        conflictingFields: [String],
        serverRecord: [String: SyncJSONValue]?
    ) throws {
        guard baseRevision >= 0, currentRevision >= 0 else {
            throw SyncContractValidationError.negativeRevision
        }
        guard (serverRecord == nil) == (currentRevision == 0),
              reason != .missingRecord || currentRevision == 0,
              conflictingFields.count <= 32,
              Set(conflictingFields).count == conflictingFields.count,
              conflictingFields.allSatisfy(SyncContractRules.isValidFieldName),
              Set(conflictingFields).isSubset(of: SyncContractRules.allowedFields(for: entityType)),
              !([.overlappingChanges, .fieldClockLost].contains(reason) && conflictingFields.isEmpty) else {
            throw SyncContractValidationError.invalidRecord
        }
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.baseRevision = baseRevision
        self.currentRevision = currentRevision
        self.reason = reason
        self.conflictingFields = conflictingFields
        self.serverRecord = serverRecord
        if let serverRecord {
            try SyncContractRules.validateRecord(
                serverRecord,
                entityType: entityType,
                entityID: entityID,
                expectedRevision: currentRevision,
                requiredClockFields: Set(conflictingFields)
            )
        }
    }

    /// Revalidates record fields whose meaning depends on the enclosing
    /// workspace response, notably the private asset object prefix.
    public func validate(for workspaceID: WorkspaceID) throws {
        guard let serverRecord else { return }
        try SyncContractRules.validateRecord(
            serverRecord,
            entityType: entityType,
            entityID: entityID,
            expectedRevision: currentRevision,
            workspaceID: workspaceID,
            requiredClockFields: Set(conflictingFields)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.serverRecord) else {
            throw SyncContractValidationError.invalidRecord
        }
        try self.init(
            operationID: container.decode(SyncOperationID.self, forKey: .operationID),
            entityType: container.decode(SyncEntityType.self, forKey: .entityType),
            entityID: container.decode(UUID.self, forKey: .entityID),
            baseRevision: container.decode(Int64.self, forKey: .baseRevision),
            currentRevision: container.decode(Int64.self, forKey: .currentRevision),
            reason: container.decode(SyncConflictReason.self, forKey: .reason),
            conflictingFields: container.decode([String].self, forKey: .conflictingFields),
            serverRecord: container.decodeIfPresent(
                [String: SyncJSONValue].self,
                forKey: .serverRecord
            )
        )
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case entityType
        case entityID = "entityId"
        case baseRevision
        case currentRevision
        case reason
        case conflictingFields
        case serverRecord
    }
}

public enum SyncOperationStatus: String, Codable, Sendable {
    case accepted
    case duplicate
    case conflict
}

public struct SyncOperationResult: Codable, Equatable, Sendable {
    public let operationID: SyncOperationID
    public let status: SyncOperationStatus
    public let revision: Int64?
    public let cursor: SyncCursor?
    public let conflict: SyncConflict?

    public init(
        operationID: SyncOperationID,
        status: SyncOperationStatus,
        revision: Int64?,
        cursor: SyncCursor?,
        conflict: SyncConflict?
    ) throws {
        self.operationID = operationID
        self.status = status
        self.revision = revision
        self.cursor = cursor
        self.conflict = conflict
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationID: container.decode(SyncOperationID.self, forKey: .operationID),
            status: container.decode(SyncOperationStatus.self, forKey: .status),
            revision: container.decodeIfPresent(Int64.self, forKey: .revision),
            cursor: container.decodeIfPresent(SyncCursor.self, forKey: .cursor),
            conflict: container.decodeIfPresent(SyncConflict.self, forKey: .conflict)
        )
    }

    public func validate() throws {
        switch status {
        case .accepted, .duplicate:
            guard let revision, revision > 0, cursor != nil, conflict == nil else {
                throw SyncContractValidationError.invalidOperationResult
            }
        case .conflict:
            guard revision == nil, cursor == nil,
                  let conflict, conflict.operationID == operationID else {
                throw SyncContractValidationError.invalidOperationResult
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case status
        case revision
        case cursor
        case conflict
    }
}

public struct SyncChange: Codable, Equatable, Sendable {
    public let cursor: SyncCursor
    public let operationID: SyncOperationID
    public let entityType: SyncEntityType
    public let entityID: UUID
    public let action: SyncMutationAction
    public let revision: Int64
    public let changedFields: [String]
    public let changedAt: Date
    public let record: [String: SyncJSONValue]

    public init(
        cursor: SyncCursor,
        operationID: SyncOperationID,
        entityType: SyncEntityType,
        entityID: UUID,
        action: SyncMutationAction,
        revision: Int64,
        changedFields: [String],
        changedAt: Date,
        record: [String: SyncJSONValue]
    ) throws {
        self.cursor = cursor
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.action = action
        self.revision = revision
        self.changedFields = changedFields
        self.changedAt = changedAt
        self.record = record
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cursor: container.decode(SyncCursor.self, forKey: .cursor),
            operationID: container.decode(SyncOperationID.self, forKey: .operationID),
            entityType: container.decode(SyncEntityType.self, forKey: .entityType),
            entityID: container.decode(UUID.self, forKey: .entityID),
            action: container.decode(SyncMutationAction.self, forKey: .action),
            revision: container.decode(Int64.self, forKey: .revision),
            changedFields: container.decode([String].self, forKey: .changedFields),
            changedAt: container.decode(Date.self, forKey: .changedAt),
            record: container.decode([String: SyncJSONValue].self, forKey: .record)
        )
    }

    public func validate() throws {
        let fieldSet = Set(changedFields)
        guard revision > 0,
              (1...32).contains(changedFields.count),
              fieldSet.count == changedFields.count,
              changedFields.allSatisfy(SyncContractRules.isValidFieldName),
              fieldSet.isSubset(of: SyncContractRules.allowedFields(for: entityType)),
              SyncContractRules.isFiniteTimestamp(changedAt),
              !(entityType == .workspace && action == .delete),
              !(changedFields.contains("createdAt") && revision != 1) else {
            throw SyncContractValidationError.invalidResponse
        }
        if action == .delete {
            guard changedFields == ["deletedAt"],
                  case .string? = record["deletedAt"] else {
                throw SyncContractValidationError.invalidResponse
            }
        }
        try SyncContractRules.validateRecord(
            record,
            entityType: entityType,
            entityID: entityID,
            expectedRevision: revision,
            requiredClockFields: fieldSet
        )
    }

    /// Applies response-scoped tenancy checks after the outer workspace ID is
    /// decoded. The standalone change envelope cannot prove an asset prefix.
    public func validate(for workspaceID: WorkspaceID) throws {
        try validate()
        if entityType == .workspace || entityType == .appearance {
            guard entityID == workspaceID.rawValue else {
                throw SyncContractValidationError.invalidResponse
            }
        }
        try SyncContractRules.validateRecord(
            record,
            entityType: entityType,
            entityID: entityID,
            expectedRevision: revision,
            workspaceID: workspaceID,
            requiredClockFields: Set(changedFields)
        )
    }

    enum CodingKeys: String, CodingKey {
        case cursor
        case operationID = "operationId"
        case entityType
        case entityID = "entityId"
        case action
        case revision
        case changedFields
        case changedAt
        case record
    }
}

public struct ActivityEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: ActivityEventID
    public let workspaceID: WorkspaceID
    public let accountID: FounderAccountID
    public let deviceID: DeviceID?
    public let kind: String
    public let entityType: SyncEntityType?
    public let entityID: UUID?
    public let occurredAt: Date
    public let metadata: [String: SyncJSONValue]

    public init(
        id: ActivityEventID,
        workspaceID: WorkspaceID,
        accountID: FounderAccountID,
        deviceID: DeviceID?,
        kind: String,
        entityType: SyncEntityType?,
        entityID: UUID?,
        occurredAt: Date,
        metadata: [String: SyncJSONValue]
    ) throws {
        self.id = id
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.deviceID = deviceID
        self.kind = kind
        self.entityType = entityType
        self.entityID = entityID
        self.occurredAt = occurredAt
        self.metadata = metadata
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ActivityEventID.self, forKey: .id),
            workspaceID: container.decode(WorkspaceID.self, forKey: .workspaceID),
            accountID: container.decode(FounderAccountID.self, forKey: .accountID),
            deviceID: container.decodeIfPresent(DeviceID.self, forKey: .deviceID),
            kind: container.decode(String.self, forKey: .kind),
            entityType: container.decodeIfPresent(SyncEntityType.self, forKey: .entityType),
            entityID: container.decodeIfPresent(UUID.self, forKey: .entityID),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            metadata: container.decode([String: SyncJSONValue].self, forKey: .metadata)
        )
    }

    public func validate() throws {
        let parts = kind.split(separator: ".", omittingEmptySubsequences: false)
        let validKind = (3...100).contains(kind.unicodeScalars.count)
            && parts.count >= 2
            && parts.allSatisfy { part in
                guard let first = part.utf8.first, (97...122).contains(first) else { return false }
                return part.utf8.dropFirst().allSatisfy {
                    (48...57).contains($0) || (97...122).contains($0)
                }
            }
        guard validKind,
              (entityType == nil) == (entityID == nil),
              metadata.isEmpty,
              SyncContractRules.isFiniteTimestamp(occurredAt) else {
            throw SyncContractValidationError.invalidActivityEvent
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case accountID = "accountId"
        case deviceID = "deviceId"
        case kind
        case entityType
        case entityID = "entityId"
        case occurredAt
        case metadata
    }
}

public struct WorkspaceBootstrap: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let session: AuthSession
    public let profile: FounderProfile
    public let workspace: [String: SyncJSONValue]
    public let startingCursor: SyncCursor
    public let latestCursor: SyncCursor

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(Int.self, forKey: .contractVersion)
        session = try container.decode(AuthSession.self, forKey: .session)
        profile = try container.decode(FounderProfile.self, forKey: .profile)
        workspace = try container.decode([String: SyncJSONValue].self, forKey: .workspace)
        startingCursor = try container.decode(SyncCursor.self, forKey: .startingCursor)
        latestCursor = try container.decode(SyncCursor.self, forKey: .latestCursor)
        guard contractVersion == SyncOperation.contractVersion,
              startingCursor.value == 0,
              latestCursor >= startingCursor,
              session.accountID == profile.accountID,
              session.identityProvider == profile.identityProvider else {
            throw SyncContractValidationError.invalidResponse
        }
        do {
            try SyncContractRules.validateRecord(
                workspace,
                entityType: .workspace,
                entityID: session.workspaceID.rawValue
            )
        } catch {
            throw SyncContractValidationError.invalidResponse
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case session
        case profile
        case workspace
        case startingCursor
        case latestCursor
    }
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let workspaceID: WorkspaceID
    public let latestCursor: SyncCursor
    public let results: [SyncOperationResult]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(Int.self, forKey: .contractVersion)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        latestCursor = try container.decode(SyncCursor.self, forKey: .latestCursor)
        results = try container.decode([SyncOperationResult].self, forKey: .results)
        guard contractVersion == SyncOperation.contractVersion,
              Set(results.map(\.operationID)).count == results.count,
              results.compactMap(\.cursor).allSatisfy({ $0 <= latestCursor }) else {
            throw SyncContractValidationError.invalidResponse
        }
        do {
            try results.compactMap(\.conflict).forEach {
                try $0.validate(for: workspaceID)
            }
        } catch {
            throw SyncContractValidationError.invalidResponse
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case workspaceID = "workspaceId"
        case latestCursor
        case results
    }
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let workspaceID: WorkspaceID
    public let fromCursor: SyncCursor
    public let nextCursor: SyncCursor
    public let latestCursor: SyncCursor
    public let hasMore: Bool
    public let changes: [SyncChange]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(Int.self, forKey: .contractVersion)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        fromCursor = try container.decode(SyncCursor.self, forKey: .fromCursor)
        nextCursor = try container.decode(SyncCursor.self, forKey: .nextCursor)
        latestCursor = try container.decode(SyncCursor.self, forKey: .latestCursor)
        hasMore = try container.decode(Bool.self, forKey: .hasMore)
        changes = try container.decode([SyncChange].self, forKey: .changes)

        let cursors = changes.map(\.cursor.value)
        let ascending = zip(cursors, cursors.dropFirst()).allSatisfy(<)
        let pageMatchesCursor = changes.isEmpty
            ? nextCursor == fromCursor
            : cursors.last == nextCursor.value
        guard contractVersion == SyncOperation.contractVersion,
              fromCursor <= nextCursor,
              nextCursor <= latestCursor,
              ascending,
              cursors.allSatisfy({ $0 > fromCursor.value && $0 <= nextCursor.value }),
              pageMatchesCursor,
              hasMore
                  ? (!changes.isEmpty && nextCursor < latestCursor)
                  : (nextCursor == latestCursor) else {
            throw SyncContractValidationError.invalidResponse
        }
        do {
            try changes.forEach { try $0.validate(for: workspaceID) }
        } catch {
            throw SyncContractValidationError.invalidResponse
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case workspaceID = "workspaceId"
        case fromCursor
        case nextCursor
        case latestCursor
        case hasMore
        case changes
    }
}

public struct AssetObjectManifestItem: Codable, Equatable, Sendable {
    public let id: UUID
    public let storagePath: String
    public let contentType: String
    public let byteSize: Int64
    public let sha256: String
    public let deletedAt: Date?

    public init(
        id: UUID,
        storagePath: String,
        contentType: String,
        byteSize: Int64,
        sha256: String,
        deletedAt: Date?
    ) throws {
        self.id = id
        self.storagePath = storagePath
        self.contentType = contentType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.deletedAt = deletedAt
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            storagePath: container.decode(String.self, forKey: .storagePath),
            contentType: container.decode(String.self, forKey: .contentType),
            byteSize: container.decode(Int64.self, forKey: .byteSize),
            sha256: container.decode(String.self, forKey: .sha256),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt)
        )
    }

    public func validate(for workspaceID: WorkspaceID? = nil) throws {
        guard SyncContractRules.isCanonicalAssetPath(
            storagePath,
            assetID: id,
            workspaceID: workspaceID
        ),
        contentType == "image/jpeg",
        (1...SyncContractRules.maximumAssetByteSize).contains(byteSize),
        sha256.utf8.count == 64,
        sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        deletedAt.map(SyncContractRules.isFiniteTimestamp) ?? true else {
            throw SyncContractValidationError.invalidAssetTransfer
        }
    }

    private func validate() throws {
        try validate(for: nil)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath
        case contentType
        case byteSize
        case sha256
        case deletedAt
    }
}

public enum AssetTransferState: String, Codable, Sendable {
    case notRequired
    case requiresPrivateStorageAdapter
    case verified
}

public struct WorkspaceAssetTransfer: Codable, Equatable, Sendable {
    public let state: AssetTransferState
    public let manifest: [AssetObjectManifestItem]

    public init(
        state: AssetTransferState,
        manifest: [AssetObjectManifestItem]
    ) throws {
        self.state = state
        self.manifest = manifest
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            state: container.decode(AssetTransferState.self, forKey: .state),
            manifest: container.decode([AssetObjectManifestItem].self, forKey: .manifest)
        )
    }

    public func validate(for workspaceID: WorkspaceID? = nil) throws {
        let uniqueIDs = Set(manifest.map(\.id)).count == manifest.count
        let uniquePaths = Set(manifest.map(\.storagePath)).count == manifest.count
        do {
            for item in manifest {
                try item.validate(for: workspaceID)
            }
        } catch {
            throw SyncContractValidationError.invalidAssetTransfer
        }
        guard uniqueIDs,
              uniquePaths,
              (state == .notRequired) == manifest.isEmpty else {
            throw SyncContractValidationError.invalidAssetTransfer
        }
    }

    private func validate() throws {
        try validate(for: nil)
    }

    enum CodingKeys: String, CodingKey {
        case state
        case manifest
    }
}

public struct WorkspaceExport: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let exportedAt: Date
    public let workspace: [String: SyncJSONValue]
    public let moves: [[String: SyncJSONValue]]
    public let appearance: [[String: SyncJSONValue]]
    public let primaryGoals: [[String: SyncJSONValue]]
    public let milestones: [[String: SyncJSONValue]]
    public let assets: [[String: SyncJSONValue]]
    public let assetTransfer: WorkspaceAssetTransfer
    public let activityEvents: [ActivityEvent]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(Int.self, forKey: .contractVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        workspace = try container.decode([String: SyncJSONValue].self, forKey: .workspace)
        moves = try container.decode([[String: SyncJSONValue]].self, forKey: .moves)
        appearance = try container.decode([[String: SyncJSONValue]].self, forKey: .appearance)
        primaryGoals = try container.decode([[String: SyncJSONValue]].self, forKey: .primaryGoals)
        milestones = try container.decode([[String: SyncJSONValue]].self, forKey: .milestones)
        assets = try container.decode([[String: SyncJSONValue]].self, forKey: .assets)
        assetTransfer = try container.decode(WorkspaceAssetTransfer.self, forKey: .assetTransfer)
        activityEvents = try container.decode([ActivityEvent].self, forKey: .activityEvents)

        guard contractVersion == SyncOperation.contractVersion,
              SyncContractRules.isFiniteTimestamp(exportedAt),
              let workspaceUUID = SyncContractRules.recordID(workspace) else {
            throw SyncContractValidationError.invalidResponse
        }
        let workspaceID = WorkspaceID(rawValue: workspaceUUID)
        try SyncContractRules.validateRecord(
            workspace,
            entityType: .workspace,
            entityID: workspaceUUID
        )
        _ = try Self.validateRecords(moves, entityType: .move)
        _ = try Self.validateRecords(appearance, entityType: .appearance)
        _ = try Self.validateRecords(primaryGoals, entityType: .primaryGoal)
        _ = try Self.validateRecords(milestones, entityType: .milestone)
        _ = try Self.validateRecords(assets, entityType: .asset, workspaceID: workspaceID)
        guard appearance.count <= 1,
              primaryGoals.filter({ Self.isLiveRecord($0) }).count <= 1,
              Set(activityEvents.map(\.id)).count == activityEvents.count,
              activityEvents.allSatisfy({
                  $0.workspaceID == workspaceID
                      && SyncContractRules.isFiniteTimestamp($0.occurredAt)
              }) else {
            throw SyncContractValidationError.invalidResponse
        }
        try assetTransfer.validate(for: workspaceID)
        try Self.validateAssetCorrespondence(
            records: assets,
            transfer: assetTransfer
        )
    }

    private static func validateRecords(
        _ records: [[String: SyncJSONValue]],
        entityType: SyncEntityType,
        workspaceID: WorkspaceID? = nil
    ) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for record in records {
            guard let id = SyncContractRules.recordID(record), ids.insert(id).inserted else {
                throw SyncContractValidationError.invalidResponse
            }
            try SyncContractRules.validateRecord(
                record,
                entityType: entityType,
                entityID: id,
                workspaceID: workspaceID
            )
        }
        return ids
    }

    private static func isLiveRecord(_ record: [String: SyncJSONValue]) -> Bool {
        guard let deletedAt = record["deletedAt"] else { return true }
        if case .null = deletedAt { return true }
        return false
    }

    private static func validateAssetCorrespondence(
        records: [[String: SyncJSONValue]],
        transfer: WorkspaceAssetTransfer
    ) throws {
        guard records.count == transfer.manifest.count else {
            throw SyncContractValidationError.invalidAssetTransfer
        }
        let manifestByID = Dictionary(uniqueKeysWithValues: transfer.manifest.map { ($0.id, $0) })
        for record in records {
            guard let id = SyncContractRules.recordID(record),
                  let item = manifestByID[id],
                  SyncContractRules.stringValue(record["storagePath"]) == item.storagePath,
                  SyncContractRules.stringValue(record["contentType"]) == item.contentType,
                  SyncContractRules.integerValue(record["byteSize"]) == item.byteSize,
                  SyncContractRules.stringValue(record["sha256"]) == item.sha256 else {
                throw SyncContractValidationError.invalidAssetTransfer
            }
            let recordDeletedAt: Date?
            if case .null? = record["deletedAt"] {
                recordDeletedAt = nil
            } else {
                recordDeletedAt = SyncContractRules.timestampValue(record["deletedAt"])
            }
            guard recordDeletedAt == item.deletedAt else {
                throw SyncContractValidationError.invalidAssetTransfer
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case exportedAt
        case workspace
        case moves
        case appearance
        case primaryGoals
        case milestones
        case assets
        case assetTransfer
        case activityEvents
    }
}

public enum AssetCleanupState: String, Codable, Sendable {
    case notRequired
    case verified
}

public struct WorkspaceEraseReceipt: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let workspaceID: WorkspaceID
    public let erasedAt: Date
    public let assetObjectCount: Int
    public let assetCleanupState: AssetCleanupState

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(Int.self, forKey: .contractVersion)
        workspaceID = try container.decode(WorkspaceID.self, forKey: .workspaceID)
        erasedAt = try container.decode(Date.self, forKey: .erasedAt)
        assetObjectCount = try container.decode(Int.self, forKey: .assetObjectCount)
        assetCleanupState = try container.decode(AssetCleanupState.self, forKey: .assetCleanupState)
        guard contractVersion == SyncOperation.contractVersion,
              SyncContractRules.isFiniteTimestamp(erasedAt),
              assetObjectCount >= 0,
              (assetCleanupState == .notRequired) == (assetObjectCount == 0) else {
            throw SyncContractValidationError.invalidResponse
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case workspaceID = "workspaceId"
        case erasedAt
        case assetObjectCount
        case assetCleanupState
    }
}

/// Session restoration is an adapter boundary. Implementations may use
/// Supabase Auth, but this core module neither stores credentials nor performs
/// network calls.
public protocol AuthSessionProviding: Sendable {
    func currentSession() async throws -> AuthSession?
}

/// Credential-free transport boundary matching the v1 RPC names. Concrete
/// HTTPS/Supabase adapters belong in a separately configured target.
public protocol WorkspaceSyncTransport: Sendable {
    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport

    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt
}

public protocol ActivityEventReading: Sendable {
    func activityEvents(workspaceID: WorkspaceID) async throws -> [ActivityEvent]
}
