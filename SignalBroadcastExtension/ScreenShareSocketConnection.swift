//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import CoreMedia
import CoreVideo

protocol ScreenShareSocketConnectionDelegate: AnyObject {
    func connectionDidClose()
    func connectionDidReceiveStopRequest()
}

/// Handles socket-based communication between the Broadcast Extension and the main Signal app.
/// Uses a Unix domain socket in the shared App Group container for efficient frame transfer.
class ScreenShareSocketConnection {

    weak var delegate: ScreenShareSocketConnectionDelegate?

    private var clientSocket: Int32 = -1
    private let socketQueue = DispatchQueue(label: "org.whispersystems.signal.screenshare.socket")
    private var isRunning = false

    private var socketPath: String {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            fatalError("Cannot access app group container")
        }
        return containerURL.appendingPathComponent("screenshare.sock").path
    }

    private var appGroupIdentifier: String {
        guard let bundleIdPrefix = Bundle.main.object(forInfoDictionaryKey: "OWSBundleIDPrefix") as? String else {
            return "group.org.whispersystems.signal.group"
        }
        return "group.\(bundleIdPrefix).signal.group"
    }

    func connect() throws {
        clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientSocket >= 0 else {
            throw SocketError.createFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let bound = ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { $0 }
            for (index, byte) in pathBytes.enumerated() {
                bound[index] = byte
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(clientSocket, $0, addrLen)
            }
        }

        guard result >= 0 else {
            close(clientSocket)
            clientSocket = -1
            throw SocketError.connectFailed
        }

        isRunning = true
        startReceiving()
    }

    func disconnect() {
        isRunning = false
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
    }

    func sendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, clientSocket >= 0 else { return }

        socketQueue.async { [weak self] in
            self?.processAndSendFrame(sampleBuffer)
        }
    }

    private func processAndSendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        // Create frame header
        var header = FrameHeader(
            width: UInt32(width),
            height: UInt32(height),
            bytesPerRow: UInt32(bytesPerRow),
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        )

        // Send header
        let headerSize = MemoryLayout<FrameHeader>.size
        let headerResult = withUnsafeBytes(of: &header) { headerPtr in
            send(clientSocket, headerPtr.baseAddress!, headerSize, 0)
        }

        guard headerResult == headerSize else {
            handleSendError()
            return
        }

        // Send pixel data
        let dataSize = bytesPerRow * height
        let dataResult = send(clientSocket, baseAddress, dataSize, 0)

        if dataResult != dataSize {
            handleSendError()
        }
    }

    private func startReceiving() {
        socketQueue.async { [weak self] in
            guard let self = self else { return }

            var buffer = [UInt8](repeating: 0, count: 1)
            while self.isRunning {
                let bytesRead = recv(self.clientSocket, &buffer, 1, 0)
                if bytesRead <= 0 {
                    DispatchQueue.main.async {
                        self.delegate?.connectionDidClose()
                    }
                    break
                }

                // Check for stop command
                if buffer[0] == ControlCommand.stop.rawValue {
                    DispatchQueue.main.async {
                        self.delegate?.connectionDidReceiveStopRequest()
                    }
                    break
                }
            }
        }
    }

    private func handleSendError() {
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.connectionDidClose()
        }
    }

    enum SocketError: Error {
        case createFailed
        case connectFailed
    }

    enum ControlCommand: UInt8 {
        case stop = 0x01
    }
}

struct FrameHeader {
    let width: UInt32
    let height: UInt32
    let bytesPerRow: UInt32
    let timestamp: Double
}
