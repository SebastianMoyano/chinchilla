import Foundation
import Testing
@testable import CastKit

@Test(.timeLimit(.minutes(1))) func fileServingWithRanges() async throws {
    // 1 KB file with known content.
    let payload = Data((0..<1024).map { UInt8($0 % 251) })
    let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("cast-test-\(UUID().uuidString).bin")
    try payload.write(to: fileURL)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let server = CastHTTPServer()
    try server.start()
    let path = server.register(file: fileURL)
    // Wait for the listener to publish its port.
    for _ in 0..<50 where server.port == 0 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(server.port > 0)
    defer { server.stopAll() }
    let base = "http://127.0.0.1:\(server.port)"

    // Full GET.
    let (full, fullResponse) = try await URLSession.shared.data(from: URL(string: base + path)!)
    #expect((fullResponse as? HTTPURLResponse)?.statusCode == 200)
    #expect(full == payload)

    // Range 0-99.
    var rangeRequest = URLRequest(url: URL(string: base + path)!)
    rangeRequest.setValue("bytes=0-99", forHTTPHeaderField: "Range")
    let (partial, partialResponse) = try await URLSession.shared.data(for: rangeRequest)
    let http = partialResponse as? HTTPURLResponse
    #expect(http?.statusCode == 206)
    #expect(partial == payload.prefix(100))
    #expect(http?.value(forHTTPHeaderField: "Content-Range") == "bytes 0-99/1024")

    // Suffix range: last 24 bytes.
    var suffixRequest = URLRequest(url: URL(string: base + path)!)
    suffixRequest.setValue("bytes=-24", forHTTPHeaderField: "Range")
    let (suffix, suffixResponse) = try await URLSession.shared.data(for: suffixRequest)
    #expect((suffixResponse as? HTTPURLResponse)?.statusCode == 206)
    #expect(suffix == payload.suffix(24))

    // Unsatisfiable range.
    var badRequest = URLRequest(url: URL(string: base + path)!)
    badRequest.setValue("bytes=5000-6000", forHTTPHeaderField: "Range")
    let (_, badResponse) = try await URLSession.shared.data(for: badRequest)
    #expect((badResponse as? HTTPURLResponse)?.statusCode == 416)

    // Unknown token.
    let (_, missing) = try await URLSession.shared.data(from: URL(string: base + "/media/nope")!)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
}
