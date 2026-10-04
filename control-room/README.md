# Signal: IPTV control room

One private React dashboard controls two personalized, developer-mode Roku sideloads. AWS CDK deploys Amplify Hosting, Cognito, a Lambda Function URL, and a DynamoDB Standard mailbox in **us-east-2**. The Rokus continue to fetch provider catalogs and play IPTV directly. [System design](../docs/iptv-dashboard-system-design.md).

## Layout and boundaries

- `../source` and `../components`: existing Roku player plus DashboardTask, DashboardBridge, and telemetry.
- `server/lambda.mjs`, `server/dynamo.mjs`: stateless Lambda API, hashed device sessions, latest snapshots, temporary commands/results.
- `server/app.mjs`, `server/schema.mjs`: shared HTTP routes and strict request/response schemas.
- `web`: responsive dashboard and Cognito authorization-code/PKCE login.
- `infra`: CDK v2 CloudFormation stack. No Lightsail, API Gateway, VM, or video proxy.
- `.private`: ignored admin, device authorization, and deployment configuration. Never commit it. The public Roku attestation certificate is bundled from `server/roku-certificates.mjs`.

Software releases in S3 and full sideload updating remain a later phase. The older in-memory `server/state.mjs` supports local tests only; it is not deployed to Lambda.

## Development checks

Install Node.js 22+, pnpm 11.25.0, and Python. From this directory:

```sh
pnpm install --frozen-lockfile
pnpm test
pnpm build
pnpm synth
```

From the repository root, also run `pnpm check` and `python3 tools/check_node_refs.py` before building a Roku ZIP. Hardware validation remains necessary even when compilation passes.

## AWS profile and CloudFormation

Use AWS CLI v2 with the already configured `cam` profile. `scripts/cdk-with-login.mjs` bridges AWS console-login credentials to CDK without writing access keys into Git. The AWS profile must resolve to the intended account:

```sh
aws login --profile cam
aws sts get-caller-identity --profile cam
```

CDK bootstrap is required once in `us-east-2` to publish the bundled Lambda asset. Bootstrap and the app stack are CloudFormation deployments:

```sh
AWS_PROFILE=cam node scripts/cdk-with-login.mjs bootstrap aws://ACCOUNT_ID/us-east-2
AWS_PROFILE=cam pnpm aws:diff -c relayConfig=.private/server.json
AWS_PROFILE=cam pnpm aws:deploy -c relayConfig=.private/server.json \
  --require-approval never --outputs-file .private/outputs.json
```

The first stack deployment may omit `relayConfig` and creates Amplify, Cognito, and the DynamoDB table. Add Lambda after assembling a private configuration. Keep `relayConfig` on later deployments; omitting it removes the API from the CloudFormation template. The `ApiUrl`/`RelayUrl` stack output is the managed HTTPS Function URL. The public URL authenticates each browser and Roku request in application code; CORS alone is not security.

## Private administrator and device provisioning

The sole Cognito administrator is created without a signup flow or invitation email. The script writes a temporary first-login password and Cognito `sub` under ignored `.private/`:

```sh
AWS_PROFILE=cam pnpm admin:create YOUR_ADMIN_EMAIL
```

### Passkey sign-in

The CDK stack enables Cognito Essentials, managed login, and WebAuthn passkeys for the existing administrator. The API still accepts only the administrator's Cognito `sub`; passkey registration does not create another dashboard account. User verification is required on the passkey device.

After deploying this stack and the dashboard, sign in once with the existing password. Select **Add passkey** in the dashboard header and finish registration on Cognito's managed login page. Then sign out and verify that passkey sign-in returns to the dashboard. Cognito's managed login asks for the account's username/email before offering its passkey, so the passkey removes routine password entry but not the username step.

The password remains available during enrollment and recovery. Do not disable password authentication until a passkey has been registered and tested on the intended devices. The existing verified email remains the account-recovery method. Keep at least one additional recovery path before narrowing sign-in factors.

Use the official Roku device-attestation certificate and verify each physical sideload's developer ID and channel ID. The provided app ZIP is not proof of a physical Roku identity. Build `.private/server.json` from the admin metadata, the trusted certificate, and zero or more verified device authorization files:

```sh
pnpm config:assemble .private/my-roku/authorization.json .private/dads-roku/authorization.json
```

For an initial backend with no enrolled Rokus, run `pnpm config:assemble` without paths. That creates a working API and dashboard with an empty device list. The script refuses to overwrite an existing configuration; prepare a revised file deliberately when adding devices. The public certificate in `.private/roku-attestation.pem` must match the bundled certificate module; CDK rejects a mismatch. Never put raw installation secrets or provider credentials in the Lambda configuration. It contains only installation-secret hashes and device IDs; the public attestation certificate is in the Lambda bundle.

After deployment, provision a separate identity for each Roku using the Function URL output:

```sh
pnpm provision my-roku 'My Roku' https://YOUR_FUNCTION_URL VERIFIED_DEVELOPER_ID
pnpm provision dads-roku 'Dad’s Roku' https://YOUR_FUNCTION_URL VERIFIED_DEVELOPER_ID
```

The resulting `dashboard.json` and `authorization.json` are ignored and must not be shared between TVs. Update `.private/server.json` with both authorization entries, then redeploy the stack. A new app process authenticates using its installation secret plus a fresh Roku-signed attestation. The app has no dashboard-pairing form.

Build the dashboard, publish it to Amplify, and build separate private Roku ZIPs. Creating a ZIP does not install it:

```sh
pnpm build
AWS_PROFILE=cam node scripts/publish-dashboard.mjs
python3 ../tools/package_personalized.py my-roku \
  --dashboard .private/my-roku/dashboard.json --provider-config ../config.json \
  --output ../builds/my-roku-v1.0.23.zip
python3 ../tools/package_personalized.py dads-roku \
  --dashboard .private/dads-roku/dashboard.json --empty-provider \
  --output ../builds/dads-roku-v1.0.23.zip
```

The current TV's favorites/recents recovery seed can be captured before replacing its sideload. From a computer on the same LAN, run `python3 ../tools/backup_roku_store.py ROKU_LAN_IP`; it uses Roku's read-only developer-mode `query/registry/dev` endpoint and saves only validated lists and the developer ID under ignored `backups/`. Roku may require **Settings → System → Advanced system settings → Control by mobile apps → Enabled** for this endpoint. If Dad is replacing an existing sideload, capture his Roku's store separately from his home network. The owner elected to build My Roku's October 3 package without a restore seed; a sideload failure or registry reset could erase favorites and recents. The earlier v1.0.20 ZIP remains untouched. Private ZIPs contain provider settings or installation secrets and stay under ignored `builds/`.

## Runtime behavior

- Roku sends one short asynchronous `POST /device/sync` about every two seconds while the IPTV app is active. It carries a snapshot and queued acknowledgments and receives at most one command.
- Browser polls current status/results while visible and slows down when hidden. Commands expire quickly and check source/catalog/playback revisions. The Roku deduplicates command IDs.
- Xtream `stream_id` is retained. M3U `tvg-id` is used only when unique; otherwise the Roku provides a catalog-scoped local ID. The browser never receives credential-bearing stream URLs.
- Provider replacement is sent as a short-lived DynamoDB command, validated and stored by the Roku, and applies on the next app launch in this version. Lambda and DynamoDB temporarily see the candidate credentials; logs do not.
- DynamoDB TTL cleanup is asynchronous. Every read also checks the logical deadline, and expired sensitive commands are explicitly deleted. The table does not hold viewing history or a full catalog.
- Session/media counters come from reported player data, not a network proxy. Missing metrics display unavailable. Cloud failures cannot interrupt direct local playback.
- A Lambda Function URL terminates public HTTPS. Application code verifies Cognito access JWTs for browser requests and a short-lived attested device session for Roku requests.
- The Function URL is the sole production CORS layer. The browser trims its trailing API URL slash before joining route paths; local Fastify runs may enable their own CORS handler.

After deploying, `AWS_PROFILE=iptv-cdk-process AWS_CONFIG_FILE=.private/aws-cdk-config node scripts/smoke-dynamo.mjs` exercises an isolated temporary mailbox record and deletes it. Run this only against the intended account and table.

Before claiming either TV is remotely controllable, validate actual Roku attestation, concurrent syncs, physical-remote races, stale-command rejection, failed provider validation, and telemetry on hardware. The full sideload package updater remains out of scope until the control room works safely.
