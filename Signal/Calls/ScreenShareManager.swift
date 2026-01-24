//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import ReplayKit
import SignalServiceKit
import WebRTC

/// Manages local screen capture using ReplayKit and provides frames
/// to the call's video pipeline via WebRTC's RTCVideoCapturer interface.
@MainActor
class ScreenShareManager: NSObject {
    private let screenRecorder = RPScreenRecorder.shared()

    private(set) var isSharing = false {
        didSet {
            guard oldValue != isSharing else { return }
            observers.elements.forEach { $0.screenShareManagerDidChangeState(self) }
        }
    }

    /// The video source that receives screen capture frames.
    /// This is created from the WebRTC PeerConnectionFactory and can be
    /// used to replace the camera source when screen sharing.
    private var videoSource: RTCVideoSource?

    /// Custom capturer that acts as a bridge between ReplayKit and WebRTC.
    private var videoCapturer: ScreenShareCapturer?

    // MARK: - Observers

    private var observers: WeakArray<any ScreenShareManagerObserver> = []

    func addObserver(_ observer: any ScreenShareManagerObserver) {
        observers.append(observer)
    }

    func removeObserver(_ observer: any ScreenShareManagerObserver) {
        observers.removeAll(where: { $0 === observer })
    }

    // MARK: - Availability

    var isAvailable: Bool {
        return screenRecorder.isAvailable
    }

    // MARK: - Start/Stop

    func startSharing() {
        guard !isSharing else {
            Logger.warn("Screen sharing already active")
            return
        }

        guard screenRecorder.isAvailable else {
            Logger.error("Screen recording is not available")
            return
        }

        let capturer = ScreenShareCapturer()
        self.videoCapturer = capturer

        screenRecorder.isMicrophoneEnabled = false
        screenRecorder.isCameraEnabled = false

        screenRecorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
            if let error {
                Logger.error("Screen capture error: \(error)")
                DispatchQueue.main.async {
                    self?.stopSharing()
                }
                return
            }

            guard sampleBufferType == .video else { return }

            capturer.didCapture(sampleBuffer: sampleBuffer)
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    Logger.error("Failed to start screen capture: \(error)")
                    self?.isSharing = false
                    self?.videoCapturer = nil
                } else {
                    Logger.info("Screen capture started successfully")
                    self?.isSharing = true
                }
            }
        })
    }

    func stopSharing() {
        guard isSharing else { return }

        screenRecorder.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    Logger.error("Failed to stop screen capture: \(error)")
                }
                self?.isSharing = false
                self?.videoCapturer = nil
                self?.videoSource = nil
                Logger.info("Screen capture stopped")
            }
        }
    }
}

// MARK: - ScreenShareCapturer

/// A lightweight bridge that converts CMSampleBuffer frames from ReplayKit
/// into RTCVideoFrames suitable for WebRTC transmission.
class ScreenShareCapturer: NSObject {
    private var lastFrameTime: CMTime = .zero

    func didCapture(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampNs = Int64(CMTimeGetSeconds(timestamp) * Double(NSEC_PER_SEC))

        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: ._0,
            timeStampNs: timestampNs
        )

        delegate?.capturer(self, didCapture: frame)
    }

    weak var delegate: ScreenShareCapturerDelegate?
}

protocol ScreenShareCapturerDelegate: AnyObject {
    func capturer(_ capturer: ScreenShareCapturer, didCapture frame: RTCVideoFrame)
}

// MARK: - Observer Protocol

protocol ScreenShareManagerObserver: AnyObject {
    @MainActor
    func screenShareManagerDidChangeState(_ manager: ScreenShareManager)
}
