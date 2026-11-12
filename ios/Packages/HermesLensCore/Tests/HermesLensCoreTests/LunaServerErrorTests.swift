import Foundation
import Testing
@testable import HermesLensCore

private func body(_ code: String) -> Data { Data(#"{"error":{"code":"\#(code)"}}"#.utf8) }

@Test func everyPluginCallRefusalHasAPlainMessage() {
    // (status, code) as adapter.py and grant.py send them → the error the user sees.
    let cases: [(Int, String?, LunaNativeError)] = [
        (401, "unauthorized", .wrongToken),
        (503, "native_provider_unavailable", .providerKeyRefused),
        (503, "native_configuration_invalid", .serverSetup),
        (503, "native_connection_failed", .providerUnreachable),
        (502, "native_provider_response_invalid", .providerUnreachable),
        (503, "native_voice_unavailable", .unavailable),
        (429, "native_usage_limit", .usageLimit),
        (429, "native_call_limit", .rateLimited),
        (429, "rate_limited", .rateLimited),
        (409, "native_call_already_active", .activeCall),
        (409, "native_call_connecting", .activeCall),
        (409, "native_request_conflict", .activeCall),
        (410, "native_call_ended", .connection),
        (400, "native_request_invalid", .incompatible),
        (400, "device_invalid", .incompatible),
        (400, "idempotency_invalid", .incompatible),
        (413, "native_request_size", .incompatible),
        (404, nil, .notLensServer),
        (500, nil, .connection),
    ]
    for (status, code, expected) in cases {
        let error = LunaNativeError(LunaServerError(status: status, code: code))
        #expect(error == expected, "\(status) \(code ?? "-")")
        #expect(error.errorDescription?.isEmpty == false)
    }
    #expect(LunaNativeError.providerKeyRefused.errorDescription?.contains("hermes lens setup") == true)
    #expect(LunaNativeError.wrongToken.errorDescription?.contains("token") == true)
    #expect(LunaNativeError.wrongToken.errorDescription != LunaNativeError.serverUnreachable.errorDescription)
}

@Test func refusalsARetryCannotFixAreNotRetried() {
    for lasting in [LunaNativeError.wrongToken, .providerKeyRefused, .serverSetup, .usageLimit, .incompatible,
                    .notLensServer, .unavailable, .serverUnreachable] {
        #expect(lasting.isLasting, "\(lasting)")
    }
    for transient in [LunaNativeError.connection, .providerUnreachable, .rateLimited, .activeCall, .audioBacklog] {
        #expect(!transient.isLasting, "\(transient)")
    }
}

@Test func serverErrorCodesAreReadFromTheBodyOnly() {
    #expect(LunaServerError(status: 404, body: body("native_approval_not_found")).isExpiredApproval)
    #expect(!LunaServerError(status: 404, body: body("native_call_not_found")).isExpiredApproval)
    #expect(LunaServerError(status: 500, body: Data("<html>oops</html>".utf8)).code == nil)
    // Provider or free text never becomes a code.
    #expect(LunaServerError(status: 503, body: body("Your key AIza… was refused")).code == nil)
}

@Test func backOfficeFailuresTellLunaWhatHappened() {
    func spoken(_ status: Int, _ code: String?) -> String { LunaServerError(status: status, code: code).spokenFailure }
    #expect(spoken(401, "unauthorized").contains("access token"))
    #expect(spoken(413, "native_photo_size").contains("too large"))
    #expect(spoken(415, "native_photo_type").contains("could not read the photo"))
    #expect(spoken(404, "native_photo_not_found").contains("no longer on the server"))
    #expect(spoken(429, "native_photo_limit").contains("four photos"))
    #expect(spoken(404, "native_call_not_found").contains("start a new call"))
    #expect(spoken(400, "native_tool_invalid").contains("Rephrase"))
    #expect(spoken(409, "native_tool_in_progress").contains("still running"))
    #expect(spoken(500, nil).contains("had a problem"))
    // None of them is the old catch-all.
    #expect(!spoken(413, "native_photo_size").contains("not reachable"))
}

@Test func healthAndSettingsFailuresTellAWrongTokenFromAnUnreachableServer() {
    #expect(HermesServerProblem(HermesClientError.httpStatus(401)) == .wrongToken)
    #expect(HermesServerProblem(HermesClientError.httpStatus(403)) == .wrongToken)
    #expect(HermesServerProblem(URLError(.cannotFindHost)) == .unreachable)
    #expect(HermesServerProblem(URLError(.timedOut)) == .unreachable)
    #expect(HermesServerProblem(HermesClientError.httpStatus(404)) == .notLensServer)
    #expect(HermesServerProblem(HermesClientError.httpStatus(502)) == .serverError(502))
    #expect(HermesServerProblem(HermesClientError.missingToken) == nil)
    #expect(HermesServerProblem.wrongToken.message != HermesServerProblem.unreachable.message)
    #expect(HermesServerProblem.wrongToken.needsSettings && !HermesServerProblem.unreachable.needsSettings)
}

@Test func approvalCardsCloseBeforeThePluginDeniesThem() {
    let shown = Date(timeIntervalSince1970: 1_000)
    #expect(LunaNativeVoice.approvalSecondsLeft(shownAt: shown, now: shown) == 118)
    #expect(LunaNativeVoice.approvalSecondsLeft(shownAt: shown, now: shown.addingTimeInterval(100)) == 18)
    #expect(LunaNativeVoice.approvalSecondsLeft(shownAt: shown, now: shown.addingTimeInterval(118)) == 0)
    #expect(LunaNativeVoice.approvalSecondsLeft(shownAt: shown, now: shown.addingTimeInterval(500)) == 0)
}
