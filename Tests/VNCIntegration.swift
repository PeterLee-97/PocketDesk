// Built against the production client on macOS by verify_vnc.py.
import Foundation
import CoreGraphics

final class Probe: VNCClientDelegate {
    let client: VNCClient
    var received = false
    init(port: Int) {
        client = VNCClient(server: .init(name: "Regression fixture", host: "127.0.0.1", port: port, password: "test1234"))
        client.delegate = self
    }
    func vncClient(_ client: VNCClient, didChange status: VNCClient.Status) {
        if case .failed(let message) = status { print("FAIL: \(message)"); exit(1) }
    }
    func vncClient(_ client: VNCClient, didResize size: CGSize) {}
    func vncClient(_ client: VNCClient, didReceiveClipboard text: String) {}
    func vncClient(_ client: VNCClient, didRenderFrame image: CGImage) {
        guard !received else { return }; received = true
        guard image.width == 4, image.height == 3,
              let bytes = image.dataProvider?.data as Data?, Array(bytes.prefix(4)) == [0,0,255,0] else { print("FAIL: framebuffer"); exit(2) }
        print("FRAME_OK 4x3 red")
        client.sendPointer(x: 2, y: 1, buttonMask: 1, force: true)
        client.sendPointer(x: 2, y: 1, buttonMask: 0, force: true)
        client.sendKeyPress(keysym: 0xFF08)
        client.sendScroll(horizontal: true, negative: true, times: 1)
        client.sendMacInputSourceToggle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { client.stop(); exit(0) }
    }
}
@main struct Main {
    static func main() {
        let probe = Probe(port: Int(CommandLine.arguments[1])!)
        probe.client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { print("FAIL: timeout, possible parser/transport deadlock"); exit(3) }
        withExtendedLifetime(probe) { RunLoop.main.run() }
    }
}
