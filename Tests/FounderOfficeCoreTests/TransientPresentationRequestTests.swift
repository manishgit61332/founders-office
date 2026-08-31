import Foundation
import Testing
@testable import FounderOfficeCore

struct TransientPresentationRequestTests {
    @Test
    func portableRequestRoundTripsWithoutPlatformTypes() throws {
        let request = TransientPresentationRequest(
            kind: .colorPanel,
            hostDisposition: .suspendExpandedHost
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            TransientPresentationRequest.self,
            from: encoded
        )

        #expect(decoded == request)
        #expect(decoded.schemaVersion == 1)
    }

    @Test
    func checkedInDraftFixtureDecodesThroughThePublicValue() throws {
        let fixtureURL = repositoryRoot.appendingPathComponent(
            "contracts/client-interfaces/draft-v1/fixtures/transient-presentation.request.json"
        )

        let request = try JSONDecoder().decode(
            TransientPresentationRequest.self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(request.kind == .colorPanel)
        #expect(request.hostDisposition == .suspendExpandedHost)
    }

    @Test
    func checkedInDraftSchemaMatchesThePublicEnums() throws {
        let schemaURL = repositoryRoot.appendingPathComponent(
            "contracts/client-interfaces/draft-v1/schemas/transient-presentation.schema.json"
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL))
                as? [String: Any]
        )
        let properties = try #require(root["properties"] as? [String: Any])
        let version = try #require(properties["schemaVersion"] as? [String: Any])
        let kind = try #require(properties["kind"] as? [String: Any])
        let disposition = try #require(properties["hostDisposition"] as? [String: Any])

        #expect(root["additionalProperties"] as? Bool == false)
        #expect(version["const"] as? Int == TransientPresentationRequest.currentSchemaVersion)
        #expect(
            Set(try #require(kind["enum"] as? [String]))
                == Set(TransientPresentationKind.allCases.map(\.rawValue))
        )
        #expect(
            Set(try #require(disposition["enum"] as? [String]))
                == Set(TransientHostDisposition.allCases.map(\.rawValue))
        )
    }

    @Test
    func unsupportedSchemaVersionFailsClosed() {
        let data = Data(
            #"{"schemaVersion":2,"kind":"menu","hostDisposition":"suspendExpandedHost"}"#
                .utf8
        )

        #expect(
            throws: TransientPresentationRequestError.unsupportedSchemaVersion(2)
        ) {
            try JSONDecoder().decode(TransientPresentationRequest.self, from: data)
        }
    }

    @Test
    func unknownFieldFailsClosed() {
        let data = Data(
            #"{"schemaVersion":1,"kind":"menu","hostDisposition":"suspendExpandedHost","window":"private"}"#
                .utf8
        )

        #expect(throws: TransientPresentationRequestError.unknownField("window")) {
            try JSONDecoder().decode(TransientPresentationRequest.self, from: data)
        }
    }

    @Test
    func unknownKindAndMissingDispositionAreRejected() {
        let unknownKind = Data(
            #"{"schemaVersion":1,"kind":"futurePanel","hostDisposition":"suspendExpandedHost"}"#
                .utf8
        )
        let missingDisposition = Data(
            #"{"schemaVersion":1,"kind":"datePicker"}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                TransientPresentationRequest.self,
                from: unknownKind
            )
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                TransientPresentationRequest.self,
                from: missingDisposition
            )
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
