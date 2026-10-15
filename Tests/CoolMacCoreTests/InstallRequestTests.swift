import Foundation
import Testing
@testable import CoolMacCore

private let session = "3F2504E0-4F89-41D3-9A0C-0305E82C3301".lowercased()
private let identifier = "d752c1be-8099-4053-b7d9-57c84500b3bb"

@Test func installUpdateRequiresACanonicalLowercaseUUID() throws {
    try ProtocolValidation.validate(ServiceRequest(operation: .installUpdate, session: session, updateID: identifier))

    #expect(throws: ProtocolValidationError.missingUpdateID) {
        try ProtocolValidation.validate(ServiceRequest(operation: .installUpdate, session: session))
    }
    for bad in ["", "not-a-uuid", identifier.uppercased(), "\(identifier)-extra", " d752c1be-8099-4053-b7d9-57c84500b3bb"] {
        #expect(throws: ProtocolValidationError.invalidUpdateID) {
            try ProtocolValidation.validate(ServiceRequest(operation: .installUpdate, session: session, updateID: bad))
        }
    }
}

@Test func onlyInstallUpdateMayCarryAnUpdateID() {
    for operation in [RequestOperation.status, .restore, .commission, .renew] {
        #expect(throws: ProtocolValidationError.unexpectedUpdateID(operation)) {
            try ProtocolValidation.validate(ServiceRequest(operation: operation, session: session, updateID: identifier))
        }
    }
    #expect(throws: ProtocolValidationError.unexpectedUpdateID(.select)) {
        try ProtocolValidation.validate(ServiceRequest(operation: .select, session: session, mode: .cool, updateID: identifier))
    }
}

@Test func installUpdateRejectsModeAndEnhancement() {
    #expect(throws: ProtocolValidationError.unexpectedMode(.installUpdate)) {
        try ProtocolValidation.validate(ServiceRequest(operation: .installUpdate, session: session, mode: .cool, updateID: identifier))
    }
    #expect(throws: ProtocolValidationError.unexpectedEnhancement(.installUpdate)) {
        try ProtocolValidation.validate(ServiceRequest(operation: .installUpdate, session: session, enhancement: 30, updateID: identifier))
    }
}
