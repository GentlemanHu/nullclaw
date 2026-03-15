# Lark Ops Readiness

This guide defines channel-specific operations checks for Lark/Feishu.

## Health Semantics

- Websocket mode is healthy only when both running and connected are true.
- Webhook mode is healthy when runtime is active and callback path is reachable.

## Auth and Permissions

1. Validate tenant token acquisition and refresh behavior.
2. Treat non-zero business code as operational failure.
3. Escalate permission/scope-like errors immediately.

## Incident Steps

1. Check app permissions/scopes in Feishu/Lark console.
2. Verify callback endpoint and websocket path availability.
3. Confirm sender allowlist (`allow_from`) and group mention behavior.
4. Restart channel worker only after root cause capture.

## SLO Signals

- auth_fail_total
- reconnect_total
- outbound_send_fail_total
- healthcheck_fail_total
