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
| `SW_DASHBOARD_ORIGINS` | Comma-separated extra origins allowed for CORS and browser writes, e.g. `https://fleet.example.com`. `http://localhost:<port>` and `http://127.0.0.1:<port>` are always allowed. `*` is ignored. |

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
  ignored. A missing or wrong token gets `401 {"error":"unauthorized"}`. Tokens are compared in
  constant time. A signed-in browser session may also call these routes (team view claim/release).
  With no token configured, these routes are open on loopback only.
- **Writes** (`POST`, `PUT`, `PATCH`, `DELETE`) must be `Content-Type: application/json`, else
  `415`; this blocks cross-site HTML form posts. The PAT login form under `/auth/` is the one exception.
- **Origin**: a write or `OPTIONS` preflight that carries an `Origin` header not in the allowlist gets
  `403`. `Access-Control-Allow-Origin` echoes allowlisted origins only and is never `*`.

Behind a public hostname or a reverse proxy, add that origin to `SW_DASHBOARD_ORIGINS`, or the
browser's writes (including sign-in) are refused with `403`.
