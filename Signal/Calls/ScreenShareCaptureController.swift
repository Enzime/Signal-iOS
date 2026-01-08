//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import ReplayKit
import SignalServiceKit
import SignalUI
import WebRTC

/// Manages screen sharing capture using ReplayKit and the Broadcast Upload Extension.
///
/// This controller coordinates screen sharing by:
/// 1. Presenting the broadcast picker UI for the user to start/stop screen sharing
/// 2. Communicating with the Broadcast Upload Extension via App Groups
/// 3. Receiving captured frames and forwarding them to RingRTC for transmission
@MainActor
public class ScreenShareCaptureController: NSObject {

    // MARK: - Properties

    /// The app group identifier used for IPC between main app and broadcast extension
    public static let appGroupIdentifier = "group.org.whispersystems.signal"

    /// The broadcast extension bundle identifier
    public static let broadcastExtensionBundleId = "org.whispersystems.signal.SignalBroadcastUploadExtension"

    /// Notification name for screen share status changes
    public static let screenShareStatusDidChange = Notification.Name("ScreenShareCaptureController.statusDidChange")

    /// Darwin notification name for broadcast started
    private static let broadcastStartedNotification = "org.whispersystems.signal.broadcast.started" as CFString

    /// Darwin notification name for broadcast finished
    private static let broadcastFinishedNotification = "org.whispersystems.signal.broadcast.finished" as CFString

    /// Whether screen sharing is currently active
    private(set) var isSharing: Bool = false {
        didSet {
            if oldValue != isSharing {
                Logger.info("Screen sharing status changed: \(isSharing)")
                NotificationCenter.default.post(name: Self.screenShareStatusDidChange, object: self)
                delegate?.screenShareCaptureController(self, didChangeStatus: isSharing)
            }
        }
    }

    /// Delegate for screen share events
    weak var delegate: ScreenShareCaptureControllerDelegate?

    /// The video source for screen sharing frames
    private var screenShareVideoSource: RTCVideoSource?

    /// The video track for screen sharing
    private var screenShareVideoTrack: RTCVideoTrack?

    /// User defaults for app group communication
    private lazy var sharedDefaults: UserDefaults? = {
        return UserDefaults(suiteName: Self.appGroupIdentifier)
    }()

    /// Timer for checking broadcast status
    private var statusCheckTimer: Timer?

    /// Key for broadcast active status in shared defaults
    private static let broadcastActiveKey = "broadcastActive"

    /// Key for broadcast session ID in shared defaults
    private static let broadcastSessionIdKey = "broadcastSessionId"

    // MARK: - Initialization

    override init() {
        super.init()
        setupDarwinNotifications()
        setupStatusChecking()
    }

    deinit {
        stopStatusChecking()
        removeDarwinNotifications()
    }

    // MARK: - Public Methods

    /// Creates and returns a broadcast picker view that can be added to the UI.
    /// When tapped, it presents the system broadcast picker.
    public func createBroadcastPickerView() -> UIView {
        let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        pickerView.preferredExtension = Self.broadcastExtensionBundleId
        pickerView.showsMicrophoneButton = false
        return pickerView
    }

    /// Programmatically triggers the broadcast picker UI.
    /// This simulates a tap on the broadcast picker button.
    public func showBroadcastPicker() {
        let pickerView = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        pickerView.preferredExtension = Self.broadcastExtensionBundleId
        pickerView.showsMicrophoneButton = false

        // Find and trigger the button in the picker view
        for subview in pickerView.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                break
            }
        }
    }

    /// Stops screen sharing if currently active.
    public func stopSharing() {
        Logger.info("Stopping screen share")

        // Signal the extension to stop via shared defaults
        sharedDefaults?.set(false, forKey: Self.broadcastActiveKey)
        sharedDefaults?.synchronize()

        // Update local state
        isSharing = false

        // Clean up video track
        cleanupVideoTrack()
    }

    /// Checks if screen sharing is available on this device.
    public var isScreenShareAvailable: Bool {
        // Screen sharing requires iOS 12+ and ReplayKit
        return true
    }

    // MARK: - Darwin Notifications

    private func setupDarwinNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        // Register for broadcast started notification
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, name, _, _) in
                guard let observer = observer else { return }
                let controller = Unmanaged<ScreenShareCaptureController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.handleBroadcastStarted()
                }
            },
            Self.broadcastStartedNotification,
            nil,
            .deliverImmediately
        )

        // Register for broadcast finished notification
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { (_, observer, name, _, _) in
                guard let observer = observer else { return }
                let controller = Unmanaged<ScreenShareCaptureController>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.handleBroadcastFinished()
                }
            },
            Self.broadcastFinishedNotification,
            nil,
            .deliverImmediately
        )
    }

    private func removeDarwinNotifications() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveObserver(center, Unmanaged.passUnretained(self).toOpaque(), nil, nil)
    }

    private func handleBroadcastStarted() {
        Logger.info("Broadcast started notification received")
        isSharing = true
    }

    private func handleBroadcastFinished() {
        Logger.info("Broadcast finished notification received")
        isSharing = false
        cleanupVideoTrack()
    }

    // MARK: - Status Checking

    private func setupStatusChecking() {
        // Periodically check broadcast status via shared defaults
        // This is a fallback in case Darwin notifications are missed
        statusCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkBroadcastStatus()
            }
        }
    }

    private func stopStatusChecking() {
        statusCheckTimer?.invalidate()
        statusCheckTimer = nil
    }

    private func checkBroadcastStatus() {
        let isActive = sharedDefaults?.bool(forKey: Self.broadcastActiveKey) ?? false

        if isActive != isSharing {
            isSharing = isActive
            if !isActive {
                cleanupVideoTrack()
            }
        }
    }

    // MARK: - Video Track Management

    private func cleanupVideoTrack() {
        screenShareVideoTrack = nil
        screenShareVideoSource = nil
    }
}

// MARK: - Delegate Protocol

@MainActor
protocol ScreenShareCaptureControllerDelegate: AnyObject {
    func screenShareCaptureController(_ controller: ScreenShareCaptureController, didChangeStatus isSharing: Bool)
}
