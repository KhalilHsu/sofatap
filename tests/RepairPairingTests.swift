import Foundation
import Darwin

// "Needs re-pairing" state through the production transport-error path.
// No network session, camera or window; reconnects are recorded, not run.
@MainActor private final class RepairFixture {
    var library = DeviceLibrary<Pairing>()
    var connections: [Pairing] = []
    var scheduled: [TimeInterval] = []
    lazy var model = ControllerModel(testPairingLibrary: library, testPairingWrite: { [unowned self] pairing in
        library.upsert(pairing); return library
    }, testPairingConnect: { [unowned self] in connections.append($0) },
    testScheduleReconnect: { [unowned self] delay, _ in scheduled.append(delay) })
    init(_ pairing: Pairing) { library.upsert(pairing) }
}

@main
struct RepairPairingTests {
    @MainActor static func main() throws {
        var passed = 0
        func check(_ name: String, _ condition: @autoclosure () throws -> Bool) rethrows {
            guard try condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let token = String(repeating: "a", count: 43)
        let link = "sofatap://pair?host=192.168.1.20&port=53319&token=\(token)&fingerprint=\(String(repeating: "a", count: 64))"
        let rescanned = "sofatap://pair?host=192.168.1.21&port=53319&token=\(String(repeating: "b", count: 43))&fingerprint=\(String(repeating: "b", count: 64))"
        let pairing = try Pairing.parse(link)

        check("pin mismatch is an explicit refusal", ControllerModel.credentialsRejected(diagnostic: "TLS_PIN", status: nil))
        check("token rejection (401) is an explicit refusal", ControllerModel.credentialsRejected(diagnostic: nil, status: 401))
        check("busy receiver (409) is not a refusal", !ControllerModel.credentialsRejected(diagnostic: nil, status: 409))
        check("certificate expiry keeps its own message", !ControllerModel.credentialsRejected(diagnostic: "TLS_VERIFY_-67901", status: nil))
        check("plain network loss is not a refusal", !ControllerModel.credentialsRejected(diagnostic: nil, status: nil))

        // Fingerprint mismatch -> needs re-pairing, no endless reconnect spinner.
        let pin = RepairFixture(pairing); pin.model.becameActive()
        check("fixture connects to the saved computer", pin.connections == [pairing] && pin.model.connecting)
        pin.model.testTransportError(diagnostic: "TLS_PIN", status: nil)
        check("fingerprint mismatch enters needs re-pairing", pin.model.needsRepairing && pin.model.repairNeededFor == pin.model.selectedDeviceID)
        check("needs re-pairing stops connecting and schedules no retry", !pin.model.connecting && !pin.model.connected && pin.scheduled.isEmpty)
        check("needs re-pairing notice", pin.model.notice == "需要重新配对")
        check("pairing is not silently forgotten", pin.model.pairing == pairing && pin.model.savedDevices.count == 1)
        pin.model.becameInactive(); pin.model.becameActive()
        check("foreground does not hammer a receiver that refused us", pin.connections.count == 1 && pin.model.needsRepairing)

        // Scan succeeds -> state clears and the new pairing connects at once.
        pin.model.acceptPairing(rescanned)
        check("successful scan clears needs re-pairing", !pin.model.needsRepairing && pin.model.repairNeededFor == nil && pin.model.pairingError == nil)
        let newPairing = try Pairing.parse(rescanned)
        check("successful scan connects the new pairing", pin.connections.last == newPairing)

        // Token rejected -> same state.
        let auth = RepairFixture(pairing); auth.model.becameActive()
        auth.model.testTransportError(diagnostic: nil, status: 401)
        check("token rejection enters needs re-pairing", auth.model.needsRepairing && auth.scheduled.isEmpty)
        auth.model.acceptPairing("not a pairing link")
        check("an invalid scan leaves needs re-pairing in place", auth.model.needsRepairing)

        // Ordinary network loss -> original reconnect path, never the re-pair screen.
        let lost = RepairFixture(pairing); lost.model.becameActive()
        lost.model.testTransportError(URLError(.networkConnectionLost), diagnostic: nil, status: nil)
        check("network loss does not ask to re-pair", !lost.model.needsRepairing)
        check("network loss keeps the reconnect schedule", lost.scheduled == [1])
        lost.model.testTransportError(URLError(.timedOut), diagnostic: nil, status: 409)
        check("busy receiver does not ask to re-pair", !lost.model.needsRepairing)

        // Expired certificate keeps the old diagnostic, not the re-pair screen.
        let expired = RepairFixture(pairing); expired.model.becameActive()
        expired.model.testTransportError(diagnostic: "TLS_VERIFY_-67901", status: nil)
        check("TLS verify failure is not the re-pair screen", !expired.model.needsRepairing && expired.model.notice.contains("TLS_VERIFY_-67901"))

        // Desktop control off (TV selected) hides the screen.
        pin.model.testTransportError(diagnostic: "TLS_PIN", status: nil)
        pin.model.setDesktopControlEnabled(false, reconnect: false)
        check("TV target never shows the computer re-pair screen", !pin.model.needsRepairing)

        print("PASS: \(passed) re-pairing checks; fingerprint/token refusals vs network loss")
    }
}
