# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | ✅ |
| Older releases | ❌ |

Only the latest release receives security updates. Please keep Textream up to date.

## Reporting a Vulnerability

If you discover a security vulnerability in Textream, **please do not open a public issue.**

Instead, report it privately:

- **Email:** [fka@fka.dev](mailto:fka@fka.dev)
- **Subject:** `[SECURITY] Textream — <brief description>`

Please include:

1. A description of the vulnerability
2. Steps to reproduce the issue
3. Potential impact
4. Suggested fix (if any)

You should receive an acknowledgment within **48 hours**. Once confirmed, a fix will be prioritized and released as soon as possible.

## Security Considerations

### On-Device Processing

All speech recognition runs locally via Apple's Speech framework. No audio data, transcripts, or scripts are sent to external servers. There are no accounts, analytics, or telemetry.

### Network Servers

Textream includes two optional network servers. Each serves a single-page web UI over HTTP and talks to it over a WebSocket on the next port:

| Server | Default Ports | Purpose |
|--------|---------------|---------|
| **Remote Connection** (BrowserServer) | `7373` (HTTP) / `7374` (WebSocket) | Read-only teleprompter mirror for a browser, with the live transcript |
| **Director Mode** (DirectorServer) | `7575` (HTTP) / `7576` (WebSocket) | Remote script editing |

**Important:**

- Both servers are **disabled by default** and must be explicitly enabled in Settings.
- Servers listen on **all interfaces**, but by default only **local network** devices may connect: loopback, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `::1`, `fe80::/10`, `fc00::/7` and IPv4-mapped IPv6 forms of these. Other addresses are disconnected at once.
- By default the WebSocket requires an **access code**: 8 characters, generated on first use with the system's secure random generator, kept in the macOS keychain and shared by both servers. The link and QR code shown in Settings carry it in the URL fragment (`http://<address>:7373/#<code>`). Browsers never send the fragment to the server, so the page itself holds no secret; opened without the right code, it asks for it.
- Until a connection sends the right code, the server sends it nothing and reads nothing else, and drops it after 5 seconds. Codes are compared in constant time. After 5 wrong codes, an address is refused for 60 seconds.
- WebSocket handshakes are refused when the browser's `Origin` is another site, or a domain name other than `localhost` or a `.local` name, which blocks cross-site WebSocket hijacking and DNS rebinding.
- Incoming WebSocket messages are capped (4 KB for Remote Connection, 1 MB for Director Mode), and so are simultaneous WebSocket connections (8 and 5).
- Both protections can be turned off in Settings → Advanced (**Ask for the access code**, **Local network only**). Without the code, anyone who can reach the ports can read the script and the live transcript and, in Director Mode, replace the script.
- Traffic is plain HTTP and WebSocket, not encrypted: anyone who can capture traffic on the network can read it, code included. Do not enable the servers on untrusted or public networks.
- Disable the servers when not in use.

### Permissions

Textream requests the following macOS permissions:

- **Microphone** — Required for speech recognition and voice-activated features.
- **Speech Recognition** — Required for on-device word tracking.
- **Local Network** — Required when Remote Connection or Director Mode is enabled.

No other permissions are requested or required.

## Recommendations

- Only enable network servers on trusted private networks.
- Keep the access code and the local network restriction on unless you have a reason to turn them off.
- Disable Remote Connection and Director Mode when not actively in use.
- Keep Textream updated to the latest version via Homebrew or GitHub Releases.
