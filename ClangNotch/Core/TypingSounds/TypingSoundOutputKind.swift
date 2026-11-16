import CoreAudio

/// What the sound output is, for 입력 효과음's "헤드폰, 이어폰일 때만".
enum TypingSoundOutputKind {
    /// Bluetooth, or the Mac's headphone jack.
    case headphones
    /// The Mac's own speakers, or a display's (HDMI, DisplayPort).
    case speakers
    /// USB and whatever else doesn't tell which it is: the user says, device by device.
    case unknown

    /// `jack`: a built-in output whose sound goes to the headphone jack.
    init(transport: UInt32, jack: Bool) {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            self = jack ? .headphones : .speakers
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            self = .speakers
        default:
            self = .unknown
        }
    }

    /// Whether the sounds play on this output. `allowed`: the user let this device in, which
    /// counts for an unknown one only.
    func plays(headphonesOnly: Bool, allowed: Bool) -> Bool {
        !headphonesOnly || self == .headphones || (self == .unknown && allowed)
    }
}
