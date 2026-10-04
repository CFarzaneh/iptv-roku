# Signal: IPTV control room

React dashboard, Node.js relay, and AWS CDK infrastructure for two privately sideloaded Roku installations. Region: **us-east-2**. AWS CLI profile used during development: **cam**. Software-update support is intentionally deferred.

## Repository layout

- `../source`, `../components`: existing Roku app plus DashboardTask, DashboardBridge, and player telemetry.
- `server`: device attestation, Cognito verification, transient command mailboxes, API.
- `web`: responsive dashboard and Cognito authorization-code/PKCE login.
- `infra`: CDK v2 stack for Amplify Hosting, Cognito, and one Lightsail container.
- `test`: isolation, replay, expiry, credential privacy, and infrastructure tests.
- `.private`: ignored local provisioning/deployment files. Never commit it.

## Development

Install Node.js 22 or newer and pnpm 11.25.0, then:

```sh
cd control-room
pnpm install --frozen-lockfile
pnpm test
pnpm build
pnpm synth
pnpm dev
```

The dashboard intentionally shows a setup state until Cognito and API settings exist. Set `VITE_API_URL`, `VITE_COGNITO_DOMAIN`, and `VITE_COGNITO_CLIENT_ID` in ignored `.env.local`, or place public deployment settings in `dist/runtime-config.json` after building. Register the exact local callback origin in a separate development Cognito client before using localhost login. Tokens are held in memory, and reloading signs in again through Cognito; only the short-lived PKCE state/verifier uses sessionStorage.

No production authentication bypass or demo credentials are compiled into the app. Tests inject verifiers into the application factory. Production always loads trusted Roku certificates and Cognito verification.

## AWS login on macOS

```sh
curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
aws configure set region us-east-2 --profile cam
aws login --profile cam
aws sts get-caller-identity --profile cam
```

The console-login flow requires AWS CLI >=2.32.0 and `SignInLocalDevelopmentAccess` for the IAM identity. Identity Center users instead configure `aws configure sso --profile cam`. No access keys belong in this repository. See the [AWS console-login guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

## Deployment

First inspect and deploy the CDK infrastructure. This creates Cognito and Amplify. Lightsail is created in a separate deployment, so the initial website deployment does not start a billable idle service.

```sh
AWS_PROFILE=cam pnpm aws:diff
AWS_PROFILE=cam pnpm aws:deploy --outputs-file .private/outputs.json
pnpm build
AWS_PROFILE=cam node scripts/publish-dashboard.mjs
```

This stack uses no CDK assets; CDK bootstrap is not required for its current resources. S3 releases, application updates, and extra database services are deferred. Keep one Node process and one Lightsail node: mailboxes and sessions are intentionally RAM-only.

Create the one administrator in Cognito without sending an invitation email. The script saves a temporary first-login password and the resulting Cognito `sub` only under ignored `.private/`. Complete the initial password change through the hosted login. No public signups are permitted.

```sh
AWS_PROFILE=cam pnpm admin:create YOUR_ADMIN_EMAIL
```

Obtain the official Roku attestation certificate and verify a challenge from each actual sideloaded installation. Record its expected developerId and channelId. Do not assume channelId `dev` proves an exact binary or physical TV. Never load verification keys from JWT-supplied URLs. Configure overlapping trusted certificates during Roku signing-key rotation.

When you are ready to activate the backend, create the one Lightsail service and its tightly scoped GitHub Actions image-builder role. The service becomes billable at this step. It has no public app until the image and private configuration are deployed:

```sh
AWS_PROFILE=cam pnpm aws:deploy -c enableRelay=true --outputs-file .private/outputs.json
```

The `RelayServiceUrl` stack output is the HTTPS endpoint to pass to `pnpm provision` for each Roku. `RelayUrl` appears only after an image and private configuration are deployed, so the published dashboard will not try to contact an unconfigured service.

Generate each installation identity separately:

```sh
pnpm provision my-roku 'My Roku' https://YOUR_RELAY_SERVICE_URL VERIFIED_DEVELOPER_ID
pnpm provision dads-roku 'Dad’s Roku' https://YOUR_RELAY_SERVICE_URL VERIFIED_DEVELOPER_ID
```

Assemble `.private/server.json` matching `server/schema.mjs`: region, origins, Cognito userPoolId/clientId/adminSub, PEM attestationCertificates, and device authorization entries. Hashes are stored on the backend; plaintext installation secrets go only into their respective personalized Roku packages. Run the backend locally with `CONTROL_ROOM_CONFIG=.private/server.json pnpm start`.

Run the `Build relay image` workflow on the fork's `main` branch. GitHub Actions builds Docker without needing Docker installed on this Mac, assumes the AWS role through a repository-and-branch-bound OIDC trust policy, and pushes only the strict `control-room` Docker context to Lightsail. It reports the immutable image name, such as `:iptv-control-room.relay.1`. For a local build instead, with Docker and the AWS Lightsail control plugin installed:

```sh
docker build --platform linux/amd64 -t iptv-control-room:local .
aws lightsail push-container-image --profile cam --region us-east-2 \
  --service-name iptv-control-room --label relay --image iptv-control-room:local
# Use the immutable image name returned above, such as :iptv-control-room.relay.1:
AWS_PROFILE=cam pnpm aws:deploy -c enableRelay=true -c relayImage=RETURNED_IMAGE_NAME \
  -c relayConfig=.private/server.json --outputs-file .private/outputs.json
pnpm build
AWS_PROFILE=cam node scripts/publish-dashboard.mjs
```

The default Amplify URL and Cognito redirects come from CDK. The publish script uploads only the built dashboard. CDK overrides relay origins and Cognito identifiers with the actual stack resources. CDK output is ignored because it can contain private authorization metadata. Keep the relayImage/relayConfig context on subsequent deployments so a redeploy does not remove the application configuration.

Copy the selected TV's private dashboard.json to `../source/dashboard.json` before packaging the Roku app with the existing deployment tooling. It is included because the existing package contains `source/`. Do not reuse one personalized package for both TVs. Existing provider settings continue working; a missing dashboard.json leaves cloud control dormant.

## Behavior and boundaries

- Direct provider-to-Roku playback; no video proxy in AWS. Existing local AAC repair stays unchanged.
- Provider `stream_id` is retained. M3U `tvg-id` is used if unique; ambiguous entries receive local IDs tied to the catalog revision.
- Categories and paged channel metadata are obtained from the Roku. Credentials and stream URLs are never exported in catalog replies.
- One outstanding 25-second command poll per app session; separate telemetry/results requests. Commands expire, are deduplicated on-device, and check catalog/playback revisions.
- Sessions require installation-secret possession plus fresh Roku attestation. They expire after 15 minutes. Browser and device permissions are separate.
- Provider replacement is validated on the device, saved in one registry record, and **applies on the next app launch in this first implementation**. Current playback is not interrupted. The form and UI explicitly state this limitation; immediate/next-tune application remains follow-up work.
- Media counters aggregate reported successful segments, not complete device/network traffic. No bandwidth proxy is introduced. Hardware validation is required for reporting completeness and event ordering.
- App exit/offline stops remote control. Backend restarts discard in-memory commands and sessions; clients authenticate again. No automatic stale-command replay.
- Lightsail terminates HTTPS before its HTTP connection to Node. Provider credentials are transient plaintext in the relay process; request/body logging is disabled.

## Before first TV deployment

Run the root BrightScript compiler and `python3 tools/check_node_refs.py`, as well as `pnpm test`, `pnpm build`, and `pnpm synth` here. Test actual attestation, simultaneous polls/reports, physical-remote races, failed credential validation, source changes, and segment measurements on hardware. Compile success does not establish Roku runtime correctness. Preserve existing registry backups before replacing a sideloaded app. No remote updater is implemented yet.
