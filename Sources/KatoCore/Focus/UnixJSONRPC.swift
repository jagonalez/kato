import Foundation

/// Newline-delimited JSON-RPC over an AF_UNIX socket — the transport both
/// cmux (`/tmp/cmux.sock`) and herdr (`~/.config/herdr/herdr.sock`) speak:
/// one request line in, one response line out.
public enum UnixJSONRPC {
    /// One newline-terminated JSON-RPC request (sorted keys for
    /// determinism/testability).
    public static func request(id: String, method: String, params: [String: String]) -> String {
        let object: [String: Any] = ["id": id, "method": method, "params": params]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Connects to the AF_UNIX socket, writes `body`, reads one
    /// newline-terminated response. 2 s receive timeout; nil on any error.
    public static func roundTrip(socketPath: String, body: String) -> String? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < pathCapacity else { return nil }
        Array(socketPath.utf8).withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyMemory(from: source)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let bytes = Array(body.utf8)
        let sent = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == bytes.count else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            response.append(contentsOf: chunk[0..<count])
            if response.contains(0x0A) { break }
        }
        guard !response.isEmpty else { return nil }
        return String(decoding: response, as: UTF8.self)
    }
}
