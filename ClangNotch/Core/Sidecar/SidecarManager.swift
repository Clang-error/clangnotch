import Foundation
import Combine

struct SidecarDeviceInfo: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    var isConnected: Bool
}

@MainActor
final class SidecarManager: ObservableObject {
    static let shared = SidecarManager()

    @Published private(set) var devices: [SidecarDeviceInfo] = []
    @Published private(set) var busyDeviceID: UUID?
    @Published private(set) var busyTarget: Bool?
    @Published private(set) var errorMessage: String?

    private let client: SidecarClientProtocol
    private let operationTimeout: TimeInterval
    private var timer: Timer?
    private var timeoutTask: Task<Void, Never>?
    private var operationID: UUID?
    private var requestAccepted = false
    private var refreshInFlight = false
    private var running = false
    private var generation = 0

    init(client: SidecarClientProtocol = SidecarClient(), operationTimeout: TimeInterval = 20) {
        self.client = client
        self.operationTimeout = operationTimeout
    }

    func start() {
        guard !running else { return }
        running = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        running = false
        generation += 1
        timer?.invalidate()
        timer = nil
        clearBusy()
    }

    func toggle(_ device: SidecarDeviceInfo) {
        guard running, busyDeviceID == nil,
              let current = devices.first(where: { $0.id == device.id }) else { return }
        let target = !current.isConnected
        let requestID = UUID()
        operationID = requestID
        requestAccepted = false
        busyDeviceID = current.id
        busyTarget = target
        errorMessage = nil

        // Independent of discovery and the private API's callback: neither may return.
        timeoutTask = Task { [weak self, operationTimeout] in
            do { try await Task.sleep(for: .seconds(operationTimeout)) } catch { return }
            guard let self, self.operationID == requestID else { return }
            self.errorMessage = target
                ? L("iPad에 연결하지 못했습니다. 전원과 Wi-Fi를 확인한 뒤 다시 시도해 주세요.", "Couldn't connect to the iPad. Check its power and Wi-Fi, then try again.")
                : L("연결 해제를 확인하지 못했습니다. 다시 시도해 주세요.", "Couldn't confirm the disconnect. Try again.")
            self.clearBusy()
        }
        client.setConnected(target, deviceID: current.id) { [weak self] error in
            Task { @MainActor in
                guard let self, self.operationID == requestID else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                    self.clearBusy()
                } else {
                    self.requestAccepted = true
                }
                // A nil callback means accepted, not connected. Poll the actual state.
                self.refresh()
            }
        }
    }

    private func clearBusy() {
        timeoutTask?.cancel()
        timeoutTask = nil
        operationID = nil
        requestAccepted = false
        busyDeviceID = nil
        busyTarget = nil
    }

    func refresh() {
        guard running, !refreshInFlight else { return }
        refreshInFlight = true
        let currentGeneration = generation
        client.fetchDevices { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.refreshInFlight = false
                guard self.running, self.generation == currentGeneration else { return }
                switch result {
                case .success(let devices):
                    if self.devices != devices { self.devices = devices }
                    if let id = self.busyDeviceID, let target = self.busyTarget {
                        let current = devices.first { $0.id == id }
                        if self.requestAccepted && (current?.isConnected == target || (!target && current == nil)) {
                            self.clearBusy()
                        } else if target && current == nil {
                            self.errorMessage = L("iPad를 더 이상 찾을 수 없습니다.", "The iPad can no longer be found.")
                            self.clearBusy()
                        }
                    }
                case .failure(let error):
                    self.devices = []
                    self.errorMessage = error.localizedDescription
                    self.clearBusy()
                }
            }
        }
    }
}
