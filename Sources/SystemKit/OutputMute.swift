import Foundation
import CoreAudio

/// Silences the Mac's speakers while something else is playing the sound.
///
/// ScreenCaptureKit *copies* system audio — it doesn't move it — so a mirrored
/// screen plays out of the TV and the Mac at once. AirPlay doesn't do that
/// because it's a system-level route, which no app can ask for. Muting the
/// default output is the honest equivalent.
///
/// The risk with muting is obvious: crash while muted and the user is left
/// with a silent Mac and no idea why. So the intent is written to disk before
/// the mute happens, and cleared only after unmuting — `restoreIfInterrupted`
/// puts the sound back on next launch. Same guard the gaming session uses for
/// frozen apps.
public enum OutputMute {
    private static let flagKey = "audio.mutedByChinchilla"

    public static var isMuted: Bool {
        guard let device = defaultOutputDevice() else { return false }
        return mutedValue(device) == 1
    }

    /// Returns false when the device has no mute control — some USB and
    /// HDMI outputs don't, and pretending otherwise would leave the user
    /// wondering why nothing happened.
    @discardableResult
    public static func mute() -> Bool {
        guard let device = defaultOutputDevice(), canMute(device) else { return false }
        UserDefaults.standard.set(true, forKey: flagKey)
        return setMuted(device, true)
    }

    @discardableResult
    public static func unmute() -> Bool {
        defer { UserDefaults.standard.removeObject(forKey: flagKey) }
        guard let device = defaultOutputDevice(), canMute(device) else { return false }
        return setMuted(device, false)
    }

    /// Call at launch: if we muted and never got to unmute, put it back.
    public static func restoreIfInterrupted() {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return }
        unmute()
    }

    // MARK: CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func canMute(_ device: AudioDeviceID) -> Bool {
        var address = muteAddress()
        return AudioObjectHasProperty(device, &address)
    }

    private static func mutedValue(_ device: AudioDeviceID) -> UInt32 {
        var address = muteAddress()
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = muteAddress()
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
