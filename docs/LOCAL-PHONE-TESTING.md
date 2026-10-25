# Local phone testing

Run `npm run dev:network`. On the same Wi-Fi, open `http://192.168.1.20:5180/preview/home` directly. No pairing, code or login is required for this explicitly enabled development session. This is the real local D1 diary: changes on the phone are real diary changes. Keep the development server running. The PC's IP may change when reconnecting to Wi-Fi.

Ignored `.dev.vars` enables this using `LOCAL_DIARY=1`, `LOCAL_LAN_ENABLED=1` and `LOCAL_LAN_HOST=192.168.1.20`. Removing the LAN flag or stopping the server disables phone access. Anyone on the local network who can reach this address can use the development diary. This is for trusted local testing, not internet exposure.

The bypass requires compile-time development mode, the exact configured private IPv4 host and port, and a private socket address. Production still requires Cloudflare Access. Same-origin write protection and PC-only provider credential setup remain enforced. Vite denies private configuration and local database files. No pairing secrets are used or stored.
