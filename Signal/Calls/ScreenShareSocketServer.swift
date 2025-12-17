//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

protocol ScreenShareSocketServerDelegate: AnyObject {
    func socketServer(_ server: ScreenShareSocketServer, didReceiveFrame frame: ScreenShareFrame)
    func socketServerDidDisconnect(_ server: ScreenShareSocketServer)
}

/// Represents a received screen share frame from the broadcast extension
struct ScreenShareFrame {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let timestamp: Double
    let pixelData: Data
}

/// Socket server that runs in the main Signal app to receive screen share frames
/// from the Broadcast Extension.
class ScreenShareSocketServer {

    weak var delegate: ScreenShareSocketServerDelegate?

    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private let socketQueue = DispatchQueue(label: "org.whispersystems.signal.screenshare.server")
    private var isRunning = false

    private var socketPath: String {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            owsFail("Cannot access app group container")
        }
        return containerURL.appendingPathComponent("screenshare.sock").path
    }

    private var appGroupIdentifier: String {
        guard let bundleIdPrefix = Bundle.main.object(forInfoDictionaryKey: "OWSBundleIDPrefix") as? String else {
            return "group.org.whispersystems.signal.group"
        }
        return "group.\(bundleIdPrefix).signal.group"
    }

    func start() throws {
        // Remove existing socket file if present
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw SocketServerError.createFailed
        }

        // Bind to path
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
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, addrLen)
            }
        }

        guard bindResult >= 0 else {
            close(serverSocket)
            serverSocket = -1
            throw SocketServerError.bindFailed
        }

        // Listen for connections
        guard listen(serverSocket, 1) >= 0 else {
            close(serverSocket)
            serverSocket = -1
            throw SocketServerError.listenFailed
        }

        isRunning = true
        startAccepting()

        Logger.info("Screen share socket server listening at: \(socketPath)")
    }

    func stop() {
        isRunning = false

        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func sendStopCommand() {
        guard clientSocket >= 0 else { return }

        socketQueue.async { [weak self] in
            guard let self = self else { return }
            var command: UInt8 = 0x01 // Stop command
            _ = send(self.clientSocket, &command, 1, 0)
        }
    }

    private func startAccepting() {
        socketQueue.async { [weak self] in
            guard let self = self else { return }

            while self.isRunning {
                // Accept connection
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

                let newClientSocket = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.serverSocket, $0, &clientAddrLen)
                    }
                }

                guard newClientSocket >= 0 else {
                    if self.isRunning {
                        Logger.warn("Accept failed, retrying...")
                        continue
                    }
                    break
                }

                // Close any existing client connection
                if self.clientSocket >= 0 {
                    close(self.clientSocket)
                }

                self.clientSocket = newClientSocket
                Logger.info("Client connected to screen share server")

                // Start receiving frames
                self.receiveFrames()
            }
        }
    }

    private func receiveFrames() {
        while isRunning && clientSocket >= 0 {
            // Read frame header
            var header = FrameHeader(width: 0, height: 0, bytesPerRow: 0, timestamp: 0)
            let headerSize = MemoryLayout<FrameHeader>.size

            let headerBytesRead = withUnsafeMutableBytes(of: &header) { headerPtr in
                recv(clientSocket, headerPtr.baseAddress!, headerSize, MSG_WAITALL)
            }

            guard headerBytesRead == headerSize else {
                Logger.info("Client disconnected or read error")
                handleDisconnect()
                break
            }

            // Read pixel data
            let dataSize = Int(header.bytesPerRow) * Int(header.height)
            var pixelData = Data(count: dataSize)

            let dataBytesRead = pixelData.withUnsafeMutableBytes { dataPtr in
                recv(clientSocket, dataPtr.baseAddress!, dataSize, MSG_WAITALL)
            }

            guard dataBytesRead == dataSize else {
                Logger.info("Failed to read pixel data")
                handleDisconnect()
                break
            }

            // Create frame and notify delegate
            let frame = ScreenShareFrame(
                width: Int(header.width),
                height: Int(header.height),
                bytesPerRow: Int(header.bytesPerRow),
                timestamp: header.timestamp,
                pixelData: pixelData
            )

            delegate?.socketServer(self, didReceiveFrame: frame)
        }
    }

    private func handleDisconnect() {
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
        delegate?.socketServerDidDisconnect(self)
    }

    enum SocketServerError: Error {
        case createFailed
        case bindFailed
        case listenFailed
    }
}

// Frame header structure (must match extension)
private struct FrameHeader {
    let width: UInt32
    let height: UInt32
    let bytesPerRow: UInt32
    let timestamp: Double
}
