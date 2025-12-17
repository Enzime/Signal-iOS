//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import ReplayKit
import CoreMedia

/// Handles screen capture samples from ReplayKit and forwards them to the main Signal app
/// for transmission during calls.
class SampleHandler: RPBroadcastSampleHandler {

    private var socketConnection: ScreenShareSocketConnection?
    private var isConnected = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        Logger.info("Screen share broadcast started")

        // Connect to the main app via local socket
        socketConnection = ScreenShareSocketConnection()
        socketConnection?.delegate = self

        do {
            try socketConnection?.connect()
            isConnected = true
            Logger.info("Connected to main app for screen sharing")
        } catch {
            Logger.error("Failed to connect to main app: \(error)")
            finishBroadcastWithError(ScreenShareError.connectionFailed)
        }

        // Notify the main app that screen sharing has started
        notifyMainApp(event: .started)
    }

    override func broadcastPaused() {
        Logger.info("Screen share broadcast paused")
        notifyMainApp(event: .paused)
    }

    override func broadcastResumed() {
        Logger.info("Screen share broadcast resumed")
        notifyMainApp(event: .resumed)
    }

    override func broadcastFinished() {
        Logger.info("Screen share broadcast finished")
        notifyMainApp(event: .finished)
        socketConnection?.disconnect()
        socketConnection = nil
        isConnected = false
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard isConnected else { return }

        switch sampleBufferType {
        case .video:
            // Send video frames to the main app
            socketConnection?.sendVideoFrame(sampleBuffer)

        case .audioApp:
            // App audio - could be sent separately if needed
            break

        case .audioMic:
            // Microphone audio is handled by the main app's call infrastructure
            break

        @unknown default:
            break
        }
    }

    private func notifyMainApp(event: ScreenShareEvent) {
        let notificationName = CFNotificationName("org.whispersystems.signal.screenshare.\(event.rawValue)" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil,
            nil,
            true
        )
    }

    enum ScreenShareEvent: String {
        case started
        case paused
        case resumed
        case finished
    }

    enum ScreenShareError: Error, LocalizedError {
        case connectionFailed
        case notInCall

        var errorDescription: String? {
            switch self {
            case .connectionFailed:
                return NSLocalizedString(
                    "SCREEN_SHARE_ERROR_CONNECTION_FAILED",
                    comment: "Error message when screen share cannot connect to the main app"
                )
            case .notInCall:
                return NSLocalizedString(
                    "SCREEN_SHARE_ERROR_NOT_IN_CALL",
                    comment: "Error message when trying to screen share but not in a call"
                )
            }
        }
    }
}

// MARK: - ScreenShareSocketConnectionDelegate

extension SampleHandler: ScreenShareSocketConnectionDelegate {
    func connectionDidClose() {
        Logger.info("Socket connection closed")
        isConnected = false
        finishBroadcastWithError(ScreenShareError.connectionFailed)
    }

    func connectionDidReceiveStopRequest() {
        Logger.info("Received stop request from main app")
        finishBroadcastWithError(nil as NSError?)
    }
}

// MARK: - Logger

private enum Logger {
    static func info(_ message: String) {
        NSLog("[SignalBroadcastExtension] INFO: %@", message)
    }

    static func error(_ message: String) {
        NSLog("[SignalBroadcastExtension] ERROR: %@", message)
    }
}
