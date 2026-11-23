# Relay

The relay connects watches to the Macs they're paired with, and sends their alerts. It's a
Cloudflare Worker with two Durable Objects:

- **`MacHub`**, one per Mac. It holds the Mac's WebSocket, its paired watches, and their push
  tokens.
- **`PairingCodes`**, a single instance. It maps live 6-digit codes to Macs.

It never sees the contents of requests; they're encrypted end to end. It does see alert text.
See [SECURITY.md](../SECURITY.md).

## Run your own

You need a Cloudflare account; the free plan works. For alerts, you also need an Apple push key
for *your* build of the app.

```bash
cd relay
npx wrangler login
npx wrangler deploy                      # gives you https://claude-watch-relay.<you>.workers.dev
```

For a custom domain, add `--domain relay.example.com`, with the domain on your Cloudflare account.

**Alerts.** On developer.apple.com → Keys, create a key with Apple Push Notifications service.
Then store it and your app's details as secrets:

```bash
npx wrangler secret put APNS_KEY       < AuthKey_XXXXXXXXXX.p8
echo XXXXXXXXXX                        | npx wrangler secret put APNS_KEY_ID
echo <your team id>                    | npx wrangler secret put APNS_TEAM_ID
echo <your prefix>.watchkitapp         | npx wrangler secret put APNS_TOPIC
```

**Use it.**

- **Mac:** `claude-watch pair --relay https://your-relay`. The bridge remembers the address.
- **Watch, by build setting:** set `RELAY_HOST = your-relay-host` in `ClaudeWatch/Local.xcconfig`
  (`configure --relay your-relay-host` does this), then rebuild.
- **Watch, by hand:** enter the address under the watch app's Settings.

## Develop

```bash
npx wrangler dev --port 8811             # a local relay
node ../bridge/server.mjs pair --relay http://127.0.0.1:8811
```

`npx wrangler tail claude-watch-relay` shows live logs, including Apple's answer to each push.

## API

| Who | Method and path | Does |
| --- | --- | --- |
| Mac | `POST /v1/macs` | sign up: returns `{macId, macSecret}` |
| Mac | `GET /v1/macs/:id/connect` (WebSocket) | first message `{type: "hello", secret}`; then receives `rpc`, sends `rpc-reply` and `push` |
| Mac | `POST /v1/macs/:id/pairing` `{pk, name}` | starts pairing, returns `{code}` |
| Mac | `GET /v1/macs/:id/pairing` | `waiting`, `joined` (with the watch's key), or `expired` |
| Mac | `POST /v1/macs/:id/pairing/confirm` `{watchId, accept}` | lets the watch in, or not |
| Mac | `GET /v1/macs/:id/watches`, `DELETE …/watches/:watchId` | list or remove watches |
| Watch | `POST /v1/join` `{code, pk, name}` | returns `{watchId, watchSecret, macPk, macName}` |
| Watch | `GET /v1/watch/status` | `{confirmed, online}` |
| Watch | `POST /v1/watch/rpc` `{box}` | an encrypted request; returns `{box}` |
| Watch | `POST /v1/watch/devices` `{token, kind, sandbox}` | where to send alerts (`app`) and watch face reloads (`widgets`) |
| Watch | `DELETE /v1/watch` | unpair |

Mac calls use `Authorization: Bearer <macSecret>`, and watch calls
`Authorization: Bearer <watchId>:<watchSecret>`.
