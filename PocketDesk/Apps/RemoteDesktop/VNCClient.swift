import Foundation
import Network
import CommonCrypto
import CoreGraphics
import QuartzCore

/// A VNC (RFB 3.8) client. Connects to a real computer's screen-sharing server and turns its
/// framebuffer into a `CGImage` the desktop can display, while sending our virtual pointer and
/// keyboard back as RFB input. This is how PocketDesk shows *real* desktop apps (anything running
/// on the host) on the external display — no jailbreak, just a standard remote-desktop protocol.
///
/// Supported encodings: Raw, CopyRect, Hextile, plus the DesktopSize and LastRect pseudo-encodings.
/// That set works against every common server (macOS Screen Sharing with a VNC password, TigerVNC,
/// x11vnc, TightVNC, RealVNC, …). Over local Wi-Fi the bandwidth is fine; we deliberately skip the
/// zlib-based encodings to keep the parser small and dependency-free.
final class VNCClient {
    enum Status: Equatable {
        case connecting
        case authenticating
        case connected
        case failed(String)
        case closed
    }

    struct Server: Equatable {
        var name: String
        var host: String
        var port: Int
        var password: String
    }

    weak var delegate: VNCClientDelegate?

    private let server: Server
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "PocketDesk.VNC")
    private let reader = ByteReader()
    private var running = false

    // Framebuffer (BGRX, one word per pixel, little-endian 0x00RRGGBB).
    private var width = 0
    private var height = 0
    private var pixels: [UInt8] = []
    private(set) var remoteName = ""

    // Input coalescing.
    private var lastPointerSend = CFTimeInterval(0)
    private var pendingButtonMask: UInt8 = 0
    private var pendingPoint = (x: 0, y: 0)
    private var pointerDirty = false

    init(server: Server) {
        self.server = server
    }

    var framebufferSize: CGSize { CGSize(width: width, height: height) }

    // MARK: Lifecycle

    func start() {
        running = true
        report(.connecting)
        let host = NWEndpoint.Host(server.host)
        let port = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, server.port)))) ?? 5900
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 12
        }
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
                self.queue.async { self.runSession() }
            case .failed(let error):
                self.fail(error.localizedDescription)
            case .cancelled:
                self.report(.closed)
            case .waiting(let error):
                self.report(.failed(Self.friendly(error)))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        guard running else { return }
        running = false
        reader.close(nil)
        connection?.cancel()
        connection = nil
    }

    private func fail(_ message: String) {
        guard running else { return }
        running = false
        reader.close(VNCError.protocolError(message))
        connection?.cancel()
        connection = nil
        report(.failed(message))
    }

    private func report(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.vncClient(self, didChange: status)
        }
    }

    private static func friendly(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED:
            return "연결이 거부되었습니다. 호스트에서 화면 공유(VNC)가 켜져 있는지, 포트가 맞는지 확인하세요."
        case .posix(let code) where code == .ETIMEDOUT:
            return "응답이 없습니다. 같은 Wi-Fi인지, 방화벽이 막고 있지 않은지 확인하세요."
        case .dns:
            return "호스트를 찾을 수 없습니다. 주소를 확인하세요."
        default:
            return error.localizedDescription
        }
    }

    // MARK: Low-level IO

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.reader.feed(data) }
            if let error {
                self.reader.close(error)
                return
            }
            if isComplete {
                self.reader.close(nil)
                return
            }
            if self.running { self.receiveLoop() }
        }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: Handshake + session (runs on `queue`, may block on reader)

    private func runSession() {
        do {
            try handshake()
            report(.connected)
            try sessionLoop()
        } catch VNCError.closed {
            report(.closed)
        } catch {
            if running { fail((error as? VNCError)?.message ?? error.localizedDescription) }
        }
    }

    private func handshake() throws {
        // ProtocolVersion.
        let serverVersion = try reader.read(12)
        _ = serverVersion
        send("RFB 003.008\n".data(using: .ascii)!)

        // Security types.
        let count = Int(try reader.read(1)[0])
        if count == 0 {
            let reasonLength = Int(try reader.readUInt32())
            let reason = String(data: try reader.read(reasonLength), encoding: .utf8) ?? "연결이 거부되었습니다"
            throw VNCError.protocolError(reason)
        }
        let types = try reader.read(count)
        report(.authenticating)
        if types.contains(1) {
            send(Data([1]))              // None
        } else if types.contains(2) {
            send(Data([2]))              // VNC authentication
            try vncAuthenticate()
        } else {
            throw VNCError.protocolError("지원하지 않는 인증 방식입니다. VNC 비밀번호 방식으로 설정해 주세요.")
        }

        // SecurityResult.
        let result = try reader.readUInt32()
        if result != 0 {
            // RFB 3.8 sends a reason string on failure.
            var reason = "인증에 실패했습니다. 비밀번호를 확인하세요."
            if let length = try? reader.readUInt32(), length > 0, length < 4096,
               let data = try? reader.read(Int(length)), let text = String(data: data, encoding: .utf8) {
                reason = text
            }
            throw VNCError.protocolError(reason)
        }

        // ClientInit: shared = 1 (don't disconnect other viewers).
        send(Data([1]))

        // ServerInit.
        width = Int(try reader.readUInt16())
        height = Int(try reader.readUInt16())
        _ = try reader.read(16)          // server pixel format (we override it below)
        let nameLength = Int(try reader.readUInt32())
        if nameLength > 0, nameLength < 4096 {
            remoteName = String(data: try reader.read(nameLength), encoding: .utf8) ?? server.name
        }
        allocateFramebuffer(width: width, height: height)

        sendPixelFormat()
        sendEncodings()
        requestFramebufferUpdate(incremental: false)
    }

    private func vncAuthenticate() throws {
        let challenge = try reader.read(16)
        let response = VNCClient.desEncrypt(challenge: challenge, password: server.password)
        send(response)
    }

    /// VNC's DES variant: each password byte has its bits reversed before use as the 8-byte key.
    static func desEncrypt(challenge: Data, password: String) -> Data {
        var key = [UInt8](repeating: 0, count: 8)
        let bytes = Array(password.utf8.prefix(8))
        for i in 0..<bytes.count {
            var value = bytes[i]
            var reversed: UInt8 = 0
            for _ in 0..<8 {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            key[i] = reversed
        }
        var output = [UInt8](repeating: 0, count: 16)
        var moved = 0
        challenge.withUnsafeBytes { input in
            _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                        key, 8, nil, input.baseAddress, 16, &output, 16, &moved)
        }
        return Data(output.prefix(moved == 0 ? 16 : moved))
    }

    private func sendPixelFormat() {
        // 32bpp, depth 24, little-endian, true colour, 0x00RRGGBB in memory as B,G,R,X.
        var message = Data([0, 0, 0, 0])     // type 0 + padding
        message.append(contentsOf: [32, 24, 0, 1])               // bpp, depth, big-endian=0, truecolour=1
        message.append(contentsOf: UInt16(255).bigEndianBytes)   // red max
        message.append(contentsOf: UInt16(255).bigEndianBytes)   // green max
        message.append(contentsOf: UInt16(255).bigEndianBytes)   // blue max
        message.append(contentsOf: [16, 8, 0])                   // red, green, blue shift
        message.append(contentsOf: [0, 0, 0])                    // padding
        send(message)
    }

    private func sendEncodings() {
        let encodings: [Int32] = [5, 1, 0, -223, -224]  // Hextile, CopyRect, Raw, DesktopSize, LastRect
        var message = Data([2, 0])
        message.append(contentsOf: UInt16(encodings.count).bigEndianBytes)
        for encoding in encodings {
            message.append(contentsOf: UInt32(bitPattern: encoding).bigEndianBytes)
        }
        send(message)
    }

    private func requestFramebufferUpdate(incremental: Bool) {
        var message = Data([3, incremental ? 1 : 0])
        message.append(contentsOf: UInt16(0).bigEndianBytes)
        message.append(contentsOf: UInt16(0).bigEndianBytes)
        message.append(contentsOf: UInt16(width).bigEndianBytes)
        message.append(contentsOf: UInt16(height).bigEndianBytes)
        send(message)
    }

    private func sessionLoop() throws {
        while running {
            let messageType = try reader.read(1)[0]
            switch messageType {
            case 0:
                try readFramebufferUpdate()
                requestFramebufferUpdate(incremental: true)
            case 1:
                try readColourMapEntries()
            case 2:
                break                        // Bell
            case 3:
                try readServerCutText()
            default:
                throw VNCError.protocolError("알 수 없는 서버 메시지(\(messageType))")
            }
        }
    }

    // MARK: Framebuffer parsing

    private func allocateFramebuffer(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = [UInt8](repeating: 0x1E, count: self.width * self.height * 4)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.vncClient(self, didResize: CGSize(width: self.width, height: self.height))
        }
    }

    private func readFramebufferUpdate() throws {
        _ = try reader.read(1)               // padding
        let rectangles = Int(try reader.readUInt16())
        var finished = false
        var index = 0
        while index < rectangles && !finished {
            let x = Int(try reader.readUInt16())
            let y = Int(try reader.readUInt16())
            let w = Int(try reader.readUInt16())
            let h = Int(try reader.readUInt16())
            let encoding = Int32(bitPattern: try reader.readUInt32())
            switch encoding {
            case 0:
                try readRaw(x: x, y: y, w: w, h: h)
            case 1:
                try readCopyRect(x: x, y: y, w: w, h: h)
            case 5:
                try readHextile(x: x, y: y, w: w, h: h)
            case -223:
                allocateFramebuffer(width: w, height: h)
                requestFramebufferUpdate(incremental: false)
            case -224:
                finished = true              // LastRect
            default:
                throw VNCError.protocolError("지원하지 않는 인코딩(\(encoding))")
            }
            index += 1
        }
        publishFrame()
    }

    private func readRaw(x: Int, y: Int, w: Int, h: Int) throws {
        guard w > 0, h > 0 else { return }
        let data = try reader.read(w * h * 4)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            blit(source: base.assumingMemoryBound(to: UInt8.self), srcStride: w * 4, x: x, y: y, w: w, h: h)
        }
    }

    private func readCopyRect(x: Int, y: Int, w: Int, h: Int) throws {
        let srcX = Int(try reader.readUInt16())
        let srcY = Int(try reader.readUInt16())
        guard w > 0, h > 0 else { return }
        let stride = width * 4
        // Copy within the framebuffer; iterate rows top-down or bottom-up to avoid overlap smear.
        let rows = srcY < y ? Array((0..<h).reversed()) : Array(0..<h)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in rows {
                let sy = srcY + row, dy = y + row
                guard sy >= 0, sy < height, dy >= 0, dy < height else { continue }
                let count = min(w, width - max(x, srcX)) * 4
                guard count > 0 else { continue }
                memmove(base + dy * stride + x * 4, base + sy * stride + srcX * 4, count)
            }
        }
    }

    private func readHextile(x: Int, y: Int, w: Int, h: Int) throws {
        var background: UInt32 = 0
        var foreground: UInt32 = 0
        var tileY = y
        while tileY < y + h {
            let tileH = min(16, y + h - tileY)
            var tileX = x
            while tileX < x + w {
                let tileW = min(16, x + w - tileX)
                let subencoding = try reader.read(1)[0]
                if subencoding & 0x01 != 0 {         // Raw tile
                    let data = try reader.read(tileW * tileH * 4)
                    data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        blit(source: base.assumingMemoryBound(to: UInt8.self), srcStride: tileW * 4, x: tileX, y: tileY, w: tileW, h: tileH)
                    }
                } else {
                    if subencoding & 0x02 != 0 { background = try readPixel() }
                    if subencoding & 0x04 != 0 { foreground = try readPixel() }
                    fill(color: background, x: tileX, y: tileY, w: tileW, h: tileH)
                    if subencoding & 0x08 != 0 {      // AnySubrects
                        let subrects = Int(try reader.read(1)[0])
                        let coloured = subencoding & 0x10 != 0
                        for _ in 0..<subrects {
                            if coloured { foreground = try readPixel() }
                            let position = try reader.read(1)[0]
                            let size = try reader.read(1)[0]
                            let sx = Int(position >> 4), sy = Int(position & 0x0F)
                            let sw = Int(size >> 4) + 1, sh = Int(size & 0x0F) + 1
                            fill(color: foreground, x: tileX + sx, y: tileY + sy, w: sw, h: sh)
                        }
                    }
                }
                tileX += tileW
            }
            tileY += tileH
        }
    }

    private func readPixel() throws -> UInt32 {
        let bytes = try reader.read(4)
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16)
    }

    private func readColourMapEntries() throws {
        _ = try reader.read(1)
        _ = try reader.read(2)
        let count = Int(try reader.readUInt16())
        _ = try reader.read(count * 6)
    }

    private func readServerCutText() throws {
        _ = try reader.read(3)
        let length = Int(try reader.readUInt32())
        guard length > 0, length < 1_000_000 else {
            if length > 0 { _ = try reader.read(length) }
            return
        }
        let data = try reader.read(length)
        if let text = String(data: data, encoding: .isoLatin1) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.vncClient(self, didReceiveClipboard: text)
            }
        }
    }

    // MARK: Pixel writes

    private func blit(source: UnsafePointer<UInt8>, srcStride: Int, x: Int, y: Int, w: Int, h: Int) {
        let stride = width * 4
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<h {
                let dy = y + row
                guard dy >= 0, dy < height else { continue }
                let copyWidth = min(w, width - x)
                guard copyWidth > 0, x >= 0 else { continue }
                memcpy(base + dy * stride + x * 4, source + row * srcStride, copyWidth * 4)
            }
        }
    }

    private func fill(color: UInt32, x: Int, y: Int, w: Int, h: Int) {
        let stride = width * 4
        let b = UInt8(color & 0xFF), g = UInt8((color >> 8) & 0xFF), r = UInt8((color >> 16) & 0xFF)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<h {
                let dy = y + row
                guard dy >= 0, dy < height else { continue }
                for column in 0..<w {
                    let dx = x + column
                    guard dx >= 0, dx < width else { continue }
                    let offset = dy * stride + dx * 4
                    base[offset] = b
                    base[offset + 1] = g
                    base[offset + 2] = r
                    base[offset + 3] = 0
                }
            }
        }
    }

    private var publishScheduled = false

    private func publishFrame() {
        guard !publishScheduled else { return }
        publishScheduled = true
        let snapshot = Data(pixels)
        let w = width, h = height
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            guard let image = VNCClient.makeImage(from: snapshot, width: w, height: h) else { return }
            self.delegate?.vncClient(self, didRenderFrame: image)
        }
    }

    private static func makeImage(from data: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, data.count >= width * height * 4 else { return nil }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Input → server

    /// `point` is in framebuffer pixels. Throttled to ~120 Hz for motion.
    func sendPointer(x: Int, y: Int, buttonMask: UInt8, force: Bool = false) {
        let clampedX = max(0, min(width - 1, x))
        let clampedY = max(0, min(height - 1, y))
        pendingPoint = (clampedX, clampedY)
        pendingButtonMask = buttonMask
        let now = CACurrentMediaTime()
        if force || buttonMask != 0 || now - lastPointerSend > 1.0 / 120 {
            flushPointer()
        } else {
            pointerDirty = true
            queue.asyncAfter(deadline: .now() + 0.012) { [weak self] in
                guard let self, self.pointerDirty else { return }
                self.flushPointer()
            }
        }
    }

    private func flushPointer() {
        pointerDirty = false
        lastPointerSend = CACurrentMediaTime()
        var message = Data([5, pendingButtonMask])
        message.append(contentsOf: UInt16(pendingPoint.x).bigEndianBytes)
        message.append(contentsOf: UInt16(pendingPoint.y).bigEndianBytes)
        send(message)
    }

    func sendScroll(up: Bool, times: Int) {
        let bit: UInt8 = up ? 0x08 : 0x10   // button 4 / button 5
        for _ in 0..<max(1, times) {
            sendButtons(mask: pendingButtonMask | bit, x: pendingPoint.x, y: pendingPoint.y)
            sendButtons(mask: pendingButtonMask & ~bit, x: pendingPoint.x, y: pendingPoint.y)
        }
    }

    private func sendButtons(mask: UInt8, x: Int, y: Int) {
        var message = Data([5, mask])
        message.append(contentsOf: UInt16(x).bigEndianBytes)
        message.append(contentsOf: UInt16(y).bigEndianBytes)
        send(message)
    }

    func sendKey(keysym: UInt32, down: Bool) {
        var message = Data([4, down ? 1 : 0, 0, 0])
        message.append(contentsOf: keysym.bigEndianBytes)
        send(message)
    }

    func sendKeyPress(keysym: UInt32) {
        sendKey(keysym: keysym, down: true)
        sendKey(keysym: keysym, down: false)
    }

    func sendClipboard(_ text: String) {
        let latin1 = text.data(using: .isoLatin1) ?? Data()
        var message = Data([6, 0, 0, 0])
        message.append(contentsOf: UInt32(latin1.count).bigEndianBytes)
        message.append(latin1)
        send(message)
    }
}

protocol VNCClientDelegate: AnyObject {
    func vncClient(_ client: VNCClient, didChange status: VNCClient.Status)
    func vncClient(_ client: VNCClient, didResize size: CGSize)
    func vncClient(_ client: VNCClient, didRenderFrame image: CGImage)
    func vncClient(_ client: VNCClient, didReceiveClipboard text: String)
}

enum VNCError: Error {
    case closed
    case protocolError(String)

    var message: String {
        switch self {
        case .closed: return "연결이 종료되었습니다"
        case .protocolError(let message): return message
        }
    }
}

/// Blocking byte reader fed by `NWConnection`. The RFB parser runs on a background queue and reads
/// exact byte counts; this lets the parser stay simple imperative code instead of a resumable state
/// machine. `read` blocks until enough bytes have arrived or the connection closes.
private final class ByteReader {
    private let condition = NSCondition()
    private var buffer: [UInt8] = []
    private var offset = 0
    private var closed = false
    private var error: Error?

    func feed(_ data: Data) {
        condition.lock()
        buffer.append(contentsOf: data)
        condition.signal()
        condition.unlock()
    }

    func close(_ error: Error?) {
        condition.lock()
        closed = true
        if self.error == nil { self.error = error }
        condition.broadcast()
        condition.unlock()
    }

    func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        condition.lock()
        defer { condition.unlock() }
        while buffer.count - offset < count {
            if closed {
                throw error.map { VNCError.protocolError(($0 as? VNCError)?.message ?? $0.localizedDescription) } ?? VNCError.closed
            }
            condition.wait()
        }
        let result = Data(buffer[offset..<offset + count])
        offset += count
        // Reclaim consumed prefix once it grows large, instead of per-read O(n) shifting.
        if offset > 1 << 20 && offset * 2 > buffer.count {
            buffer.removeFirst(offset)
            offset = 0
        }
        return result
    }

    func readUInt16() throws -> UInt16 {
        let data = try read(2)
        return (UInt16(data[0]) << 8) | UInt16(data[1])
    }

    func readUInt32() throws -> UInt32 {
        let data = try read(4)
        return (UInt32(data[0]) << 24) | (UInt32(data[1]) << 16) | (UInt32(data[2]) << 8) | UInt32(data[3])
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}
