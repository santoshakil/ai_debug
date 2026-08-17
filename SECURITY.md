# Security

ai_debug runs inside the app and can expose sensitive runtime data. Release
startup is blocked unless `allowRelease: true` is set explicitly. Keep it in
debug or controlled internal builds.

- loopback is the default and recommended bind address
- loopback prevents LAN access but is not app-private; another local process may
  connect, so authentication is always required
- every config has an explicit or randomly generated access token
- keep fixed tokens in an ignored local environment file and out of logs,
  source control, screenshots, and shared reports
- a non-loopback bind requires explicit `unsafeLan: true` and uses plain HTTP
- `/healthz` and the static dashboard shell are public; debug data and commands
  require the token
- file access requires explicit absolute roots
- use read-only, stable file roots; writable roots can change during a request
- app state and network requests require explicit instrumentation
- automation, runtime controls, outbound probes, telemetry, VM service access,
  and mDNS are opt-in
- outbound probes can resolve and connect to private addresses; enable them only
  for a trusted local client
- telemetry accepts HTTPS collectors and loopback HTTP only
- widget, semantics, error, log, route, and state data can contain private app
  content even when a tool is read-only
- do not register secrets, tokens, private headers, raw request bodies, or
  personal data

Report security issues through a
[private GitHub security advisory](https://github.com/santoshakil/ai_debug/security/advisories/new)
instead of opening a public issue.
