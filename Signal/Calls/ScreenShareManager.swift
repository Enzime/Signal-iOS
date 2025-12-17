//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import ReplayKit
import SignalRingRTC
import SignalServiceKit
import WebRTC

/// Manages screen sharing functionality for Signal calls.
/// Coordinates between the Broadcast Extension and RingRTC.
@MainActor
class ScreenShareManager: NSObject {

    // MARK: - Singleton

    static let shared = ScreenShareManager()

    // MARK: - Properties

    private(set) var isScreenSharing = false {
        didSet {
            if oldValue != isScreenSharing {
                observers.elements.forEach { $0.screenShareStateDidChange(isSharing: isScreenSharing) }
            }
        }
    }

    private var socketServer: ScreenShareSocketServer?
    private var observers: WeakArray<any ScreenShareManagerObserver> = []

    /// The video source used for screen sharing frames
    private var screenShareVideoSource: RTCVideoSource?
    private var screenShareVideoCapturer: RTCVideoCapturer?

    // MARK: - Initialization

    private override init() {
        super.init()
        setupNotificationObservers()
    }

    // MARK: - Public API

    /// Presents the system broadcast picker to start screen sharing
    func startScreenShare(from viewController: UIViewController) {
        guard !isScreenSharing else {
            Logger.warn("Screen sharing already active")
            return
        }

        // Check if we're in a call
        guard AppEnvironment.shared.callServiceRef.callServiceState.currentCall != nil else {
            Logger.warn("Cannot start screen share - not in a call")
            showNotInCallAlert(from: viewController)
            return
        }

        // Start the socket server before presenting the picker
        startSocketServer()

        // Present the system broadcast picker
        presentBroadcastPicker(from: viewController)
    }

    /// Stops the current screen sharing session
    func stopScreenShare() {
        guard isScreenSharing else { return }

        Logger.info("Stopping screen share")

        // Send stop command to extension
        socketServer?.sendStopCommand()

        // Clean up
        cleanupScreenShare()
    }

    // MARK: - Observers

    func addObserver(_ observer: ScreenShareManagerObserver) {
        observers.append(observer)
    }

    func removeObserver(_ observer: ScreenShareManagerObserver) {
        observers.removeAll { $0 === observer }
    }

    // MARK: - Private Methods

    private func setupNotificationObservers() {
        // Listen for Darwin notifications from the broadcast extension
        let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

        let events: [(String, (ScreenShareManager) -> Void)] = [
            ("org.whispersystems.signal.screenshare.started", { manager in
                Task { @MainActor in manager.handleBroadcastStarted() }
            }),
            ("org.whispersystems.signal.screenshare.paused", { manager in
                Task { @MainActor in manager.handleBroadcastPaused() }
            }),
            ("org.whispersystems.signal.screenshare.resumed", { manager in
                Task { @MainActor in manager.handleBroadcastResumed() }
            }),
            ("org.whispersystems.signal.screenshare.finished", { manager in
                Task { @MainActor in manager.handleBroadcastFinished() }
            })
        ]

        for (eventName, _) in events {
            CFNotificationCenterAddObserver(
                notificationCenter,
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, _ in
                    guard let observer = observer,
                          let name = name else { return }

                    let manager = Unmanaged<ScreenShareManager>.fromOpaque(observer).takeUnretainedValue()
                    let nameString = name.rawValue as String

                    if nameString.contains("started") {
                        Task { @MainActor in manager.handleBroadcastStarted() }
                    } else if nameString.contains("paused") {
                        Task { @MainActor in manager.handleBroadcastPaused() }
                    } else if nameString.contains("resumed") {
                        Task { @MainActor in manager.handleBroadcastResumed() }
                    } else if nameString.contains("finished") {
                        Task { @MainActor in manager.handleBroadcastFinished() }
                    }
                },
                eventName as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    private func startSocketServer() {
        socketServer = ScreenShareSocketServer()
        socketServer?.delegate = self
        do {
            try socketServer?.start()
            Logger.info("Screen share socket server started")
        } catch {
            Logger.error("Failed to start socket server: \(error)")
        }
    }

    private func presentBroadcastPicker(from viewController: UIViewController) {
        let broadcastPicker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        broadcastPicker.preferredExtension = broadcastExtensionBundleId
        broadcastPicker.showsMicrophoneButton = false

        // Find the button and trigger it
        for subview in broadcastPicker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                return
            }
        }

        // Fallback: add picker to view temporarily
        viewController.view.addSubview(broadcastPicker)
        broadcastPicker.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            broadcastPicker.removeFromSuperview()
        }
    }

    private var broadcastExtensionBundleId: String {
        guard let mainBundleId = Bundle.main.bundleIdentifier else {
            return "org.whispersystems.signal.SignalBroadcastExtension"
        }
        // Remove ".Signal" suffix if present and add extension identifier
        let baseBundleId = mainBundleId.replacingOccurrences(of: ".Signal", with: "")
        return "\(baseBundleId).SignalBroadcastExtension"
    }

    private func handleBroadcastStarted() {
        Logger.info("Broadcast started notification received")
        isScreenSharing = true
        updateRingRTCScreenShareState(isSharing: true)
    }

    private func handleBroadcastPaused() {
        Logger.info("Broadcast paused notification received")
        // Keep isScreenSharing true but potentially update UI
    }

    private func handleBroadcastResumed() {
        Logger.info("Broadcast resumed notification received")
    }

    private func handleBroadcastFinished() {
        Logger.info("Broadcast finished notification received")
        cleanupScreenShare()
    }

    private func cleanupScreenShare() {
        isScreenSharing = false
        updateRingRTCScreenShareState(isSharing: false)
        socketServer?.stop()
        socketServer = nil
        screenShareVideoSource = nil
        screenShareVideoCapturer = nil
    }

    private func updateRingRTCScreenShareState(isSharing: Bool) {
        guard let currentCall = AppEnvironment.shared.callServiceRef.callServiceState.currentCall else {
            return
        }

        switch currentCall.mode {
        case .groupThread(let call as GroupCall), .callLink(let call as GroupCall):
            // For group calls, RingRTC handles the presenting state
            // The frames will be sent through the video capturer
            if isSharing {
                Logger.info("Screen sharing enabled for group call")
            } else {
                Logger.info("Screen sharing disabled for group call")
            }
        case .individual(let call):
            // For individual calls, update the presenting state
            if isSharing {
                Logger.info("Screen sharing enabled for individual call")
            } else {
                Logger.info("Screen sharing disabled for individual call")
            }
        }
    }

    private func showNotInCallAlert(from viewController: UIViewController) {
        let alert = UIAlertController(
            title: OWSLocalizedString(
                "SCREEN_SHARE_NOT_IN_CALL_TITLE",
                comment: "Title for alert when trying to screen share outside of a call"
            ),
            message: OWSLocalizedString(
                "SCREEN_SHARE_NOT_IN_CALL_MESSAGE",
                comment: "Message for alert when trying to screen share outside of a call"
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: CommonStrings.okButton,
            style: .default
        ))
        viewController.present(alert, animated: true)
    }
}

// MARK: - ScreenShareSocketServerDelegate

extension ScreenShareManager: ScreenShareSocketServerDelegate {
    nonisolated func socketServer(_ server: ScreenShareSocketServer, didReceiveFrame frame: ScreenShareFrame) {
        Task { @MainActor in
            self.processReceivedFrame(frame)
        }
    }

    nonisolated func socketServerDidDisconnect(_ server: ScreenShareSocketServer) {
        Task { @MainActor in
            Logger.info("Socket server disconnected")
            if self.isScreenSharing {
                self.cleanupScreenShare()
            }
        }
    }

    @MainActor
    private func processReceivedFrame(_ frame: ScreenShareFrame) {
        guard isScreenSharing else { return }

        // Convert the frame to RTCVideoFrame and send to RingRTC
        // This would interface with the VideoCaptureController to push screen frames
        // The actual implementation depends on RingRTC's API for screen share sources

        // For now, log that we received a frame
        Logger.verbose("Received screen share frame: \(frame.width)x\(frame.height)")
    }
}

// MARK: - ScreenShareManagerObserver

protocol ScreenShareManagerObserver: AnyObject {
    func screenShareStateDidChange(isSharing: Bool)
}

// MARK: - Logger Extension

private extension Logger {
    static func verbose(_ message: String) {
        // Only log in debug builds to avoid performance impact
        #if DEBUG
        Logger.info(message)
        #endif
    }
}
