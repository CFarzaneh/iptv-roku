import { readFileSync } from 'node:fs';
import { Stack, CfnOutput, Duration, RemovalPolicy, Tags } from 'aws-cdk-lib';
import { UserPool, OAuthScope, AccountRecovery, FeaturePlan, ManagedLoginVersion, PasskeyUserVerification, CfnManagedLoginBranding } from 'aws-cdk-lib/aws-cognito';
import { CfnApp, CfnBranch } from 'aws-cdk-lib/aws-amplify';
import { AttributeType, BillingMode, Table, TableEncryption } from 'aws-cdk-lib/aws-dynamodb';
import { Architecture, FunctionUrlAuthType, Runtime } from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';
import { fileURLToPath } from 'node:url';
import { serverConfig } from '../server/schema.mjs';
import { rokuAttestationCertificates } from '../server/roku-certificates.mjs';
import { loginBranding } from './login-branding.mjs';

export class ControlRoomStack extends Stack {
  constructor(scope, id, props = {}) {
    super(scope, id, props);
    Tags.of(this).add('Project', 'iptv-control-room');
    const site = new CfnApp(this, 'Dashboard', {
      name: 'iptv-control-room', platform: 'WEB',
      customRules: [{ source: '</^[^.]+$|\\.(?!(css|gif|ico|jpg|js|png|txt|svg|woff|woff2|ttf|map|json)$)([^.]+$)/>', target: '/index.html', status: '200' }],
      customHeaders: `customHeaders:\n  - pattern: '**/*'\n    headers:\n      - key: X-Content-Type-Options\n        value: nosniff\n      - key: Referrer-Policy\n        value: no-referrer\n      - key: X-Frame-Options\n        value: DENY\n      - key: Permissions-Policy\n        value: camera=(), microphone=(), geolocation=()\n`,
    });
    new CfnBranch(this, 'Production', { appId: site.attrAppId, branchName: 'main', enableAutoBuild: false, stage: 'PRODUCTION' });
    const website = `https://main.${site.attrDefaultDomain}/`;
    const pool = new UserPool(this, 'Administrators', {
      userPoolName: 'iptv-control-room-admin', selfSignUpEnabled: false,
      signInAliases: { username: true, email: true },
      keepOriginal: { email: true },
      accountRecovery: AccountRecovery.EMAIL_ONLY,
      passwordPolicy: { minLength: 14, requireDigits: true, requireLowercase: true, requireUppercase: true, requireSymbols: true },
      featurePlan: FeaturePlan.ESSENTIALS,
      signInPolicy: { allowedFirstAuthFactors: { password: true, passkey: true } },
      passkeyUserVerification: PasskeyUserVerification.REQUIRED,
      removalPolicy: RemovalPolicy.RETAIN,
    });
    const client = pool.addClient('DashboardClient', {
      generateSecret: false, preventUserExistenceErrors: true,
      authFlows: { user: true, userSrp: true },
      oAuth: { flows: { authorizationCodeGrant: true }, scopes: [OAuthScope.OPENID, OAuthScope.EMAIL, OAuthScope.COGNITO_ADMIN], callbackUrls: [website], logoutUrls: [website] },
      accessTokenValidity: Duration.minutes(15), idTokenValidity: Duration.minutes(15), refreshTokenValidity: Duration.hours(12),
      enableTokenRevocation: true,
    });
    const domain = pool.addDomain('LoginDomain', { cognitoDomain: { domainPrefix: `iptv-control-${this.account}-${this.region}` },
      managedLoginVersion: ManagedLoginVersion.NEWER_MANAGED_LOGIN });
    const branding = new CfnManagedLoginBranding(this, 'LoginBranding', {
      userPoolId: pool.userPoolId, clientId: client.userPoolClientId, settings: loginBranding,
    });
    branding.node.addDependency(domain);
    const table = new Table(this, 'Mailbox', {
      tableName: 'iptv-control-room', partitionKey: { name: 'PK', type: AttributeType.STRING },
      sortKey: { name: 'SK', type: AttributeType.STRING },
      billingMode: BillingMode.PROVISIONED, readCapacity: 5, writeCapacity: 5,
      timeToLiveAttribute: 'expiresAt', encryption: TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: false },
      removalPolicy: RemovalPolicy.DESTROY,
    });
    if (props.configurationPath) {
      const cfg = serverConfig.parse(JSON.parse(readFileSync(props.configurationPath, 'utf8')));
      if (JSON.stringify(cfg.attestationCertificates) !== JSON.stringify(rokuAttestationCertificates))
        throw Error('Private config attestation certificate differs from bundled public certificate.');
      const { attestationCertificates: _publicCertificates, ...runtimeConfig } = cfg;
      const runtime = { ...runtimeConfig, region: 'us-east-2', userPoolId: pool.userPoolId,
        clientId: client.userPoolClientId, origins: [website.slice(0, -1)] };
      const logGroup = new LogGroup(this, 'ApiLogs', {
        logGroupName: '/aws/lambda/iptv-control-room-api', retention: RetentionDays.ONE_WEEK,
        removalPolicy: RemovalPolicy.DESTROY,
      });
      const api = new NodejsFunction(this, 'Api', {
        functionName: 'iptv-control-room-api', entry: fileURLToPath(new URL('../server/lambda.mjs', import.meta.url)), handler: 'handler',
        runtime: Runtime.NODEJS_22_X, architecture: Architecture.ARM_64,
        memorySize: 128, timeout: Duration.seconds(15), logGroup,
        bundling: { minify: true, sourceMap: false, target: 'node22', externalModules: [] },
        environment: { TABLE_NAME: table.tableName, CONTROL_ROOM_CONFIG_JSON: this.toJsonString(runtime) },
      });
      table.grantReadWriteData(api);
      const url = api.addFunctionUrl({ authType: FunctionUrlAuthType.NONE,
        cors: { allowedOrigins: [website.slice(0, -1)], allowedMethods: ['GET', 'POST'], allowedHeaders: ['Authorization', 'Content-Type'] } });
      new CfnOutput(this, 'ApiUrl', { value: url.url });
      new CfnOutput(this, 'RelayUrl', { value: url.url });
    }
    new CfnOutput(this, 'Region', { value: this.region });
    new CfnOutput(this, 'DashboardUrl', { value: website });
    new CfnOutput(this, 'AmplifyAppId', { value: site.attrAppId });
    new CfnOutput(this, 'UserPoolId', { value: pool.userPoolId });
    new CfnOutput(this, 'ClientId', { value: client.userPoolClientId });
    new CfnOutput(this, 'LoginUrl', { value: domain.baseUrl() });
  }
}
