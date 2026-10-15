import Foundation
import Testing
@testable import CoolMacCore

private let canonicalSession = "123E4567-E89B-12D3-A456-426614174000"
private let operations: [RequestOperation] = [.status, .select, .renew, .restore, .commission]
private let operationsWithoutMode: [RequestOperation] = [.status, .renew, .restore, .commission]

struct ProtocolValidationTests {
    @Test(arguments: CoolingMode.allCases)
    func selectRequiresAndAcceptsEveryKnownMode(mode: CoolingMode) throws {
        try ProtocolValidation.validate(ServiceRequest(operation: .select, session: canonicalSession, mode: mode))
    }

    @Test func selectWithoutModeIsRejected() {
        #expect(throws: ProtocolValidationError.missingMode) {
            try ProtocolValidation.validate(ServiceRequest(operation: .select, session: canonicalSession))
        }
    }

    @Test(arguments: operationsWithoutMode)
    func otherOperationsAcceptOnlyRequestsWithoutMode(operation: RequestOperation) throws {
        try ProtocolValidation.validate(ServiceRequest(operation: operation, session: canonicalSession))
        for mode in CoolingMode.allCases {
            #expect(throws: ProtocolValidationError.unexpectedMode(operation)) {
                try ProtocolValidation.validate(ServiceRequest(operation: operation, session: canonicalSession, mode: mode))
            }
        }
    }

    @Test(arguments: [-1, 0, Product.protocolVersion + 1, Int.max])
    func protocolVersionMustMatchExactly(version: Int) {
        for operation in operations {
            var request = ServiceRequest(operation: operation, session: canonicalSession, mode: operation == .select ? .cool : nil)
            request.version = version
            #expect(throws: ProtocolValidationError.unsupportedVersion(version)) {
                try ProtocolValidation.validate(request)
            }
        }
    }

    @Test func supportedVersionIsAccepted() throws {
        var request = ServiceRequest(operation: .status, session: canonicalSession)
        request.version = Product.protocolVersion
        try ProtocolValidation.validate(request)
    }

    @Test(arguments: [
        "123E4567-E89B-12D3-A456-426614174000",
        "123e4567-e89b-12d3-a456-426614174000",
        "123e4567-E89b-12d3-a456-426614174000",
        "00000000-0000-0000-0000-000000000000",
    ])
    func canonicalUUIDIsCaseInsensitiveAndDoesNotImposeAnUnrequestedUUIDVersion(session: String) throws {
        for operation in operations {
            try ProtocolValidation.validate(ServiceRequest(operation: operation, session: session, mode: operation == .select ? .cool : nil))
        }
    }

    @Test(arguments: [
        "",
        "not-a-session",
        "123E4567E89B12D3A456426614174000",
        "123E4567-E89B-12D3-A456-42661417400",
        "123E4567-E89B-12D3-A456-4266141740000",
        "123E4567-E89B-12D3-A456-42661417400Z",
        "123E4567_E89B-12D3-A456-426614174000",
        " 123E4567-E89B-12D3-A456-426614174000",
        "123E4567-E89B-12D3-A456-426614174000 ",
        "123E4567-E89B-12D3-A456-426614174000\n",
        "{123E4567-E89B-12D3-A456-426614174000}",
        "urn:uuid:123E4567-E89B-12D3-A456-426614174000",
        "123E4567-E89B-12D3-A456-42661417400\0",
        "１２３E4567-E89B-12D3-A456-426614174000",
    ])
    func nonCanonicalOrMalformedSessionIsRejectedForEveryOperation(session: String) {
        for operation in operations {
            #expect(throws: ProtocolValidationError.invalidSession) {
                try ProtocolValidation.validate(ServiceRequest(operation: operation, session: session, mode: operation == .select ? .cool : nil))
            }
        }
    }

    @Test func errorPrecedenceIsVersionThenSessionThenOperationShape() {
        var request = ServiceRequest(operation: .select, session: "invalid")
        request.version = Product.protocolVersion + 1
        #expect(throws: ProtocolValidationError.unsupportedVersion(Product.protocolVersion + 1)) {
            try ProtocolValidation.validate(request)
        }
        request.version = Product.protocolVersion
        #expect(throws: ProtocolValidationError.invalidSession) {
            try ProtocolValidation.validate(request)
        }
    }

    @Test func localizedErrorsExplainTheRejectedInput() throws {
        let errors: [ProtocolValidationError] = [
            .unsupportedVersion(999), .invalidSession, .missingMode, .unexpectedMode(.commission),
        ]
        for error in errors {
            let description = try #require(error.errorDescription)
            #expect(!description.isEmpty)
            #expect(error.localizedDescription == description)
        }
        #expect(ProtocolValidationError.unexpectedMode(.commission).localizedDescription.contains("commission"))
    }

    @Test func decodedValidRequestIsValidatedWithoutChangingItsMeaning() throws {
        let original = ServiceRequest(operation: .select, session: canonicalSession.lowercased(), mode: .boost)
        let decoded = try JSONDecoder().decode(ServiceRequest.self, from: JSONEncoder().encode(original))
        try ProtocolValidation.validate(decoded)
        #expect(decoded.version == Product.protocolVersion)
        #expect(decoded.session == original.session)
        #expect(decoded.operation == .select)
        #expect(decoded.mode == .boost)
    }

    @Test func decodingRejectsUnknownOperationsAndModesBeforeValidation() {
        for json in [
            "{\"version\":1,\"operation\":\"execute\",\"session\":\"\(canonicalSession)\"}",
            "{\"version\":1,\"operation\":\"select\",\"session\":\"\(canonicalSession)\",\"mode\":\"custom-rpm\"}",
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(ServiceRequest.self, from: Data(json.utf8))
            }
        }
    }
}
