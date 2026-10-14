# Dashboard exposure

How the dashboard server (`dashboard/server.ts`) decides who may call it. Spec §6.2
"Dashboard exposure"; the policy lives in `dashboard/services/request-guard.ts` and
`dashboard/services/auth-flow.ts`.

## Configuration

| Variable | Meaning |
| --- | --- |
| `SW_DASHBOARD_HOST` (or `shipwright dashboard --host`) | Bind address. Default `127.0.0.1`. |
| `SHIPWRIGHT_FLEET_TOKEN` | Shared secret for fleet workers (trimmed). Set the same value on every worker. |
| `SHIPWRIGHT_FLEET_TOKEN_FILE` | Path to a file holding the token, used when the variable above is unset or blank. An unreadable or empty file stops startup. |
| `GITHUB_PAT` + `DASHBOARD_REPO`, or `GITHUB_CLIENT_ID` + `GITHUB_CLIENT_SECRET` + `DASHBOARD_REPO` | Browser sign-in (PAT or OAuth). With neither, auth is `none`. |
| `SW_DASHBOARD_ORIGINS` | Comma-separated public origins of the dashboard, e.g. `https://fleet.example.com`. Each is normalized with `new URL(o).origin` (lowercase, default port and path dropped); entries that are not `http(s)` URLs, including `*`, are ignored. `http://localhost:<port>`, `http://127.0.0.1:<port>` and `http://[::1]:<port>` are always allowed. Listed hosts are accepted as `Host` on a loopback bind, and a non-loopback one marks the dashboard as exposed (below). |
| `SW_DASHBOARD_SECURE_COOKIE=1` | Mark the session and OAuth-state cookies `Secure`. Automatic when any `SW_DASHBOARD_ORIGINS` entry is `https://`. |

## Exposed or local

The dashboard is **exposed** when it binds a non-loopback address, or when it binds loopback but
`SW_DASHBOARD_ORIGINS` names a non-loopback host (it sits behind a reverse proxy). An exposed
dashboard needs browser sign-in and a fleet token, or it refuses to start.

A reverse proxy that rewrites `Host` to `127.0.0.1` (nginx `proxy_set_header Host 127.0.0.1`, or
`proxy_pass http://127.0.0.1:8767` without `proxy_set_header Host $host`) is just as public, but
the dashboard cannot tell from the request. Whenever a proxy fronts it, list the public origin in
`SW_DASHBOARD_ORIGINS`, which turns on the exposed-mode checks, and configure sign-in and a fleet
token. Never run `auth=none` behind a proxy.

## Startup

| Bind | `SW_DASHBOARD_ORIGINS` | Auth | Fleet token | Result |
| --- | --- | --- | --- | --- |
| loopback | loopback hosts only, or unset | any | any | starts |
| loopback | names a non-loopback host | `none` | any | exits 1: `refusing to serve … behind a proxy … with auth=none` |
| loopback | names a non-loopback host | PAT or OAuth | unset | exits 1: `… without SHIPWRIGHT_FLEET_TOKEN` |
| other | any | `none` | any | exits 1: `refusing to serve … with auth=none` |
| other | any | PAT or OAuth | unset | exits 1: `… without SHIPWRIGHT_FLEET_TOKEN` |
| other, or proxied loopback | any | PAT or OAuth | set | starts |
| any | any | any | `SHIPWRIGHT_FLEET_TOKEN_FILE` unreadable or empty | exits 1 |

The startup banner says whether a fleet token is configured and lists the allowed origins; it
never prints the token.

## Requests

Checks run in this order, before any route:

1. **Host**: a malformed `Host` gets `400`. On a loopback bind, a `Host` other than `localhost`,
   `127.0.0.1`, `[::1]` or a host from `SW_DASHBOARD_ORIGINS` gets `421` (DNS rebinding), for HTTP
   and WebSocket alike.
2. **Fetch metadata**: a request to `/api/*`, `/ws*` or `/auth/*` whose `Sec-Fetch-Site` is present
   and is not `same-origin` or `none` (so `cross-site` or `same-site`) gets `403`. This stops other
   sites, including sibling subdomains, from loading API data, join scripts or sockets in a victim's
   browser. The OAuth callback, which is a navigation back from github.com, is exempt. Clients that
   send no `Sec-Fetch-Site` (curl, workers) are unaffected.
3. **WebSocket origin**: an upgrade (`/ws`, `/ws/events`, or any `Upgrade: websocket`) whose
   `Origin` is not allowlisted gets `403`. This also runs before the local-connection bypass.
4. **Origin on writes**: a write or `OPTIONS` preflight carrying a non-allowlisted `Origin` gets `403`.
5. **JSON-only writes**: `POST`, `PUT`, `PATCH` and `DELETE` must be `Content-Type: application/json`,
   else `415`; this blocks cross-site HTML form posts. Forms under `/auth/` (PAT login, logout) are
   exempt and rely on the Origin and fetch-metadata checks.
6. **Fleet routes** (`/api/claim`, `/api/claim/release`, `/api/connect/*`, `/api/webhook/ci`) need
   `X-Shipwright-Token: <token>` (or `Authorization: Bearer <token>`, any case) or a signed-in
   session. A token in the query string is ignored. A missing or wrong token gets
   `401 {"error":"unauthorized"}`. Tokens are compared as SHA-256 digests with `timingSafeEqual`, so
   neither the content nor the length leaks through timing. When the dashboard is not exposed and
   no token is set, these routes are open.

`Access-Control-Allow-Origin` echoes allowlisted origins only and is never `*`.

## Browser sign-in

- The UI signs in with GitHub (PAT or OAuth), then uses the `fleet_session` cookie (`HttpOnly`,
  `SameSite=Lax`, `Secure` when configured). The browser never holds the fleet token, and the
  WebSockets use the same cookie. When the dashboard is not exposed and auth is `none`, no sign-in
  is needed. The "local connection" WebSocket bypass applies only then, and only for an exact
  loopback `Host`.
- **OAuth `state`**: `/auth/github` issues a random 256-bit state and sets it in an `HttpOnly`,
  `SameSite=Lax` `oauth_state` cookie (path `/auth`, 10 minutes). `/auth/callback` requires the query
  `state` to equal the cookie and to be one the server issued and has not used. A state is single
  use: any attempt, right or wrong, burns it. Otherwise the callback answers `400`.
- **Sign-out** is `POST /auth/logout` (Origin- and fetch-metadata-checked). `GET /auth/logout`, which
  the UI's "Sign out" links use, only shows a one-button form that posts it.
- **Safari and `Secure`**: Safari (WebKit) may not store a `Secure` cookie set over plain
  `http://localhost`, unlike Chrome and Firefox, which treat localhost as a secure context. With
  `Secure` on, sign in through the `https://` origin, not `http://localhost:<port>`.

## Join tokens

`GET /api/join/{token}` serves the worker join script once. An unknown or already-redeemed token
gets `410` and a script that only prints an error, so a leaked join URL cannot be replayed.

## Known Bun issue

On Bun 1.2.19, a synchronous subprocess (`execSync` or `Bun.spawnSync`) inside a WebSocket `open`
handler segfaults the server when the client drops the TCP connection without a close frame. The
dashboard used to do that: `open` sent the fleet state, and the CPU count came from running
`sysctl -n hw.ncpu` synchronously. It now counts CPUs with `os.availableParallelism()` once at
startup, sends the initial state on the next tick, and checks `readyState` before every send.
Keep WebSocket handlers free of synchronous subprocesses. Minimal reproduction (`ws.ts`):

```ts
Bun.serve({
  port: 8799,
  fetch: (req, srv) => (srv.upgrade(req) ? undefined : new Response("x")),
  websocket: { open(ws) { Bun.spawnSync(["true"]); ws.send("hi"); }, message() {} },
});
```

Then send a WebSocket handshake to `/` over a raw TCP socket and destroy the socket once
`101 Switching Protocols` arrives. Bun prints `panic(main thread): Segmentation fault at address 0x0`.
