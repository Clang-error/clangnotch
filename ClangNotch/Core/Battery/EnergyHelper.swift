import Foundation
import Security
import ServiceManagement
import XPC

/// The energy mode helper (`EnergyHelper/ClangNotchEnergyHelper.c`): a launchd daemon that sets the
/// Mac's energy mode as root, so the switch under the Battery tab's Mac row works without a
/// password each time. Optional (user, 2026-11-18): installed only from that row's button, after
/// macOS's approval in System Settings -> General -> Login Items; removed from Settings -> Features.
/// Each side checks the other's signature: the helper only answers this app signed by its team, and
/// the app only talks to a helper signed by the team it is signed by itself.
enum EnergyHelper {
    static let label = "com.clangerror.ClangNotch.EnergyHelper"

    enum State: Equatable { case notInstalled, needsApproval, installed }

    private static var service: SMAppService { .daemon(plistName: label + ".plist") }

    /// An XPC round trip to the system: read it when the row opens, not on every redraw.
    static var state: State {
        switch service.status {
        case .enabled: return .installed
        case .requiresApproval: return .needsApproval
        default: return .notInstalled
        }
    }

    /// Registers the daemon; macOS then wants it allowed in Login Items, which this opens.
    static func install() -> State {
        do { try service.register() } catch { debugLog("[EnergyHelper] register: \(error)") }
        let now = state
        if now == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
        return now
    }

    static func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    static func uninstall() async {
        do { try await service.unregister() } catch { debugLog("[EnergyHelper] unregister: \(error)") }
    }

    /// Sets the mode for both power sources through the helper. Blocks for the round trip: call it
    /// off the main thread. False when the helper is missing, isn't ours, or pmset failed.
    static func set(_ mode: MacEnergyMode, _ capabilities: MacEnergyMode.Capabilities) -> Bool {
        guard let requirement = helperRequirement else { return false }
        let connection = xpc_connection_create_mach_service(label, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        guard xpc_connection_set_peer_code_signing_requirement(connection, requirement) == 0 else { return false }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        defer { xpc_connection_cancel(connection) }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(message, "mode", mode.pmsetNumber)
        xpc_dictionary_set_bool(message, "threeWay", capabilities.threeWay)
        xpc_dictionary_set_bool(message, "highPower", capabilities.highPower)
        let reply = xpc_connection_send_message_with_reply_sync(connection, message)
        return xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_bool(reply, "ok")
    }

    /// The helper must carry its own identifier and this app's team, read from this app's signature.
    private static let helperRequirement: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return "anchor apple generic and identifier \"\(label)\" and certificate leaf[subject.OU] = \"\(team)\""
    }()
}
