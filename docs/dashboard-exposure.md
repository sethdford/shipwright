# Dashboard exposure

How the dashboard server (`dashboard/server.ts`) decides who may call it. Spec §6.2
"Dashboard exposure"; the policy lives in `dashboard/services/request-guard.ts`.

## Configuration

| Variable | Meaning |
| --- | --- |
| `SW_DASHBOARD_HOST` (or `shipwright dashboard --host`) | Bind address. Default `127.0.0.1`. |
| `SHIPWRIGHT_FLEET_TOKEN` | Shared secret for fleet workers. Set the same value on every worker. |
| `SHIPWRIGHT_FLEET_TOKEN_FILE` | Path to a file holding the token (used when the variable above is unset). An unreadable or empty file stops startup. |
| `GITHUB_PAT` + `DASHBOARD_REPO`, or `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET` + `DASHBOARD_REPO` | Browser sign-in (PAT or OAuth). With neither, auth is `none`. |
| `SW_DASHBOARD_ORIGINS` | Comma-separated extra origins allowed for CORS, browser writes and WebSockets, e.g. `https://fleet.example.com`. `http://localhost:<port>`, `http://127.0.0.1:<port>` and `http://[::1]:<port>` are always allowed. `*` is ignored. Their hostnames are also accepted as `Host` on a loopback bind. |
| `SW_DASHBOARD_SECURE_COOKIE=1` | Mark the session cookie `Secure`. This is automatic when any `SW_DASHBOARD_ORIGINS` entry is `https://`. Set it when TLS ends at a proxy whose origin you have not listed. |

## Startup

| Bind | Auth | Fleet token | Result |
| --- | --- | --- | --- |
| loopback (`127.0.0.1`, `localhost`, `::1`) | any | any | starts |
| other | `none` | any | exits 1: `refusing to bind … with auth=none` |
| other | PAT or OAuth | unset | exits 1: `refusing to bind … without SHIPWRIGHT_FLEET_TOKEN` |
| other | PAT or OAuth | set | starts |
| any | any | `SHIPWRIGHT_FLEET_TOKEN_FILE` unreadable or empty | exits 1 |

The startup banner says whether a fleet token is configured; it never prints the token.

## Requests

- **Browser UI** signs in with GitHub (PAT or OAuth) and then uses the `fleet_session` cookie
  (`HttpOnly`, `SameSite=Lax`). The browser never holds the fleet token, and the WebSocket
  (`/ws`, `/ws/events`) uses the same cookie. On a loopback bind with auth `none`, no sign-in is needed.
- **Fleet workers** (`/api/claim`, `/api/claim/release`, `/api/connect/*`, `/api/webhook/ci`) send
  `X-Shipwright-Token: <token>` (or `Authorization: Bearer <token>`). A token in the query string is
  ignored; the `Bearer` scheme is case-insensitive. A missing or wrong token gets
  `401 {"error":"unauthorized"}`. Tokens are trimmed, and compared as SHA-256 digests with
  `timingSafeEqual`, so neither the content nor the length leaks through timing. A signed-in browser session may also call these routes (team view claim/release).
  With no token configured, these routes are open on loopback only.
- **Writes** (`POST`, `PUT`, `PATCH`, `DELETE`) must be `Content-Type: application/json`, else
  `415`; this blocks cross-site HTML form posts. The PAT login form under `/auth/` is the one exception.
- **Host (DNS rebinding)**: on a loopback bind, a request whose `Host` is not `localhost`,
  `127.0.0.1`, `[::1]` or a host from `SW_DASHBOARD_ORIGINS` gets `421`, for HTTP and WebSocket
  alike. A public bind does not check `Host`; it relies on sign-in and the fleet token.
- **WebSocket origin**: an upgrade (`/ws`, `/ws/events`, or any `Upgrade: websocket`) whose
  `Origin` is not allowlisted gets `403` before the loopback bypass, so another site cannot open
  the socket from a victim's browser. Clients that send no `Origin` (non-browser) are unaffected.
- **Sign-out** is `POST /auth/logout` (Origin-checked). `GET /auth/logout`, which the UI's
  "Sign out" links use, only shows a one-button form that posts it.
- **Origin**: a write or `OPTIONS` preflight that carries an `Origin` header not in the allowlist gets
  `403`. `Access-Control-Allow-Origin` echoes allowlisted origins only and is never `*`.

Behind a public hostname or a reverse proxy, add that origin to `SW_DASHBOARD_ORIGINS`, or the
browser's writes (including sign-in) are refused with `403`.
