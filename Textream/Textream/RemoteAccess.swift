import Foundation
import Network
import Security

/// Who may use the remote view and Director: one access code shared by both
/// servers, kept in the keychain, and the checks each connection goes through.
enum RemoteAccess {
    /// No 0/o, 1/l/i: the code can be read off the screen and typed by hand.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    static let codeLength = 8

    private static let keychainService = "io.github.bouliw.Takeline.remote"
    private static var cachedCode: String?
    private static var failures: [String: (count: Int, last: Date)] = [:]

    // MARK: - Access Code

    /// The code, read from the keychain or created there on first use.
    static var code: String {
        if let cachedCode { return cachedCode }
        if let stored = readCode(), stored.count == codeLength {
            cachedCode = stored
            return stored
        }
        return regenerate()
    }

    /// Replaces the code; devices already connected stay connected.
    @discardableResult
    static func regenerate() -> String {
        let code = generateCode()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(code.utf8)
        SecItemAdd(item as CFDictionary, nil)
        cachedCode = code
        return code
    }

    static func generateCode() -> String {
        // Bytes past the last multiple of the alphabet size are dropped, so every character is equally likely.
        let limit = UInt8(256 - 256 % alphabet.count)
        var code = ""
        while code.count < codeLength {
            var bytes = [UInt8](repeating: 0, count: codeLength)
            precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
            for byte in bytes where byte < limit && code.count < codeLength {
                code.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return code
    }

    private static func readCode() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Compares in constant time, so response timing tells nothing about a guess.
    static func codesMatch(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        return a.count == b.count && timingsafe_bcmp(a, b, a.count) == 0
    }

    /// The address to open on another device. The code rides in the fragment,
    /// which browsers never send to the server, so the page itself holds no secret.
    static func shareURL(host: String, port: UInt16) -> String {
        let url = "http://\(host):\(port)"
        return NotchSettings.shared.remoteRequiresCode ? "\(url)/#\(code)" : url
    }

    // MARK: - Connection Checks

    /// Whether a new connection may go on: devices outside the local network are
    /// refused when that setting is on, and so is an address locked out for wrong codes.
    static func admits(_ conn: NWConnection) -> Bool {
        if NotchSettings.shared.remoteLocalNetworkOnly && !isLocal(conn.endpoint) { return false }
        return !isLockedOut(conn.endpoint)
    }

    /// Reads the first message of a WebSocket, `{"type":"auth","text":"<code>"}`.
    /// A wrong code closes the connection and counts against the sender's address.
    static func authenticate(_ data: Data, from conn: NWConnection) -> Bool {
        guard NotchSettings.shared.remoteRequiresCode else { return true }
        let message = data.count <= 256 ? try? JSONDecoder().decode(AuthMessage.self, from: data) : nil
        if let message, message.type == "auth", codesMatch(message.text, code) { return true }
        // A page opened without a code asks for one; only actual guesses count.
        if message?.text.isEmpty == false { recordFailure(conn.endpoint) }
        refuse(conn)
        return false
    }

    /// Closes with "policy violation" (1008), which the page takes as "ask for the code".
    private static func refuse(_ conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.policyViolation)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        conn.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private struct AuthMessage: Decodable {
        let type: String
        let text: String
    }

    /// After five wrong codes, an address is refused for a minute.
    static func isLockedOut(_ endpoint: NWEndpoint) -> Bool {
        guard let failure = failures[address(of: endpoint)] else { return false }
        return failure.count >= 5 && Date().timeIntervalSince(failure.last) < 60
    }

    static func recordFailure(_ endpoint: NWEndpoint) {
        let now = Date()
        failures = failures.filter { now.timeIntervalSince($0.value.last) < 60 }
        let key = address(of: endpoint)
        failures[key] = ((failures[key]?.count ?? 0) + 1, now)
    }

    private static func address(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    /// Loopback, private and link-local addresses, IPv4 or IPv6.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isLocalIPv4([UInt8](address.rawValue))
        case .ipv6(let address): return isLocalIPv6([UInt8](address.rawValue))
        default: return false
        }
    }

    private static func isLocalIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 127 || b[0] == 10                // loopback, 10/8
            || (b[0] == 172 && b[1] & 0xF0 == 16)       // 172.16/12
            || (b[0] == 192 && b[1] == 168)             // 192.168/16
            || (b[0] == 169 && b[1] == 254)             // link-local
    }

    private static func isLocalIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            return isLocalIPv4(Array(b[12...]))         // IPv4-mapped
        }
        return b == [UInt8](repeating: 0, count: 15) + [1]  // ::1
            || (b[0] == 0xFE && b[1] & 0xC0 == 0x80)        // fe80::/10
            || b[0] & 0xFE == 0xFC                          // fc00::/7
    }

    // MARK: - WebSocket Handshake

    /// Options for both WebSocket listeners: a cap on incoming messages, and a
    /// handshake check that turns away pages from other sites.
    static func webSocketOptions(httpPort: UInt16, maximumMessageSize: Int) -> NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.maximumMessageSize = maximumMessageSize
        options.setClientRequestHandler(.main) { _, headers in
            func header(_ name: String) -> String? {
                headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            }
            let allowed = allowsOrigin(header("Origin"), host: header("Host"), httpPort: httpPort)
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        return options
    }

    /// Browsers always send Origin; other clients may not, and still need the code.
    /// The page must come from our HTTP port on the host the socket was opened with,
    /// and that host must be an address or a local name: a site that rebinds its own
    /// domain to this Mac (DNS rebinding) is turned away.
    static func allowsOrigin(_ origin: String?, host: String?, httpPort: UInt16) -> Bool {
        guard let origin else { return true }
        guard let host,
              let page = URLComponents(string: origin), page.scheme == "http", page.port == Int(httpPort),
              let pageHost = page.host?.lowercased(),
              pageHost == URLComponents(string: "http://\(host)")?.host?.lowercased() else { return false }
        let bare = pageHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare.hasSuffix(".local")
            || IPv4Address(bare) != nil || IPv6Address(bare) != nil
    }

    // MARK: - Page

    /// Shown by both pages when the code is missing or wrong. Defines `accessCode()`
    /// and `askCode()`; submitting stores the code in the fragment and calls `connect()`.
    static let codePromptHTML = """
        <style>
        #code-prompt{display:none;position:fixed;inset:0;z-index:200;background:#000;
          flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:24px}
        #code-prompt.show{display:flex}
        #code-prompt .msg{font-size:15px;color:rgba(255,255,255,.6);text-align:center;
          max-width:320px;line-height:1.5}
        #code-input{width:220px;padding:10px 14px;border-radius:12px;
          border:1px solid rgba(255,255,255,.15);background:rgba(255,255,255,.08);color:#fff;
          font:inherit;font-size:20px;letter-spacing:.15em;text-align:center;outline:none}
        #code-prompt button{border:0;border-radius:12px;padding:10px 24px;background:#facc15;
          color:#000;font:inherit;font-size:14px;font-weight:600;cursor:pointer}
        </style>
        <form id="code-prompt">
          <div class="msg">Enter the access code shown in Takeline's settings</div>
          <input id="code-input" autocomplete="off" autocapitalize="off" autocorrect="off"
            spellcheck="false" maxlength="32" aria-label="Access code">
          <button type="submit">Connect</button>
        </form>
        <script>
        function accessCode(){return location.hash.slice(1)}
        function askCode(){
          document.getElementById('code-prompt').classList.add('show');
          document.getElementById('code-input').focus();
        }
        document.getElementById('code-prompt').addEventListener('submit',e=>{
          e.preventDefault();
          const v=document.getElementById('code-input').value.trim().toLowerCase();
          if(!v)return;
          location.hash=v;
          document.getElementById('code-prompt').classList.remove('show');
          connect();
        });
        // A link with the code pasted into this tab
        addEventListener('hashchange',()=>{
          const f=document.getElementById('code-prompt');
          if(f.classList.contains('show')){f.classList.remove('show');connect()}
        });
        </script>
        """
}
