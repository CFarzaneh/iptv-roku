import { readFileSync } from 'node:fs';
import { Stack, CfnOutput, Duration, RemovalPolicy, Tags, LegacyStackSynthesizer } from 'aws-cdk-lib';
import { UserPool, OAuthScope, AccountRecovery } from 'aws-cdk-lib/aws-cognito';
import { CfnApp, CfnBranch } from 'aws-cdk-lib/aws-amplify';
import { CfnContainer } from 'aws-cdk-lib/aws-lightsail';
import { OidcProviderNative, PolicyStatement, Role, WebIdentityPrincipal } from 'aws-cdk-lib/aws-iam';
import { serverConfig } from '../server/schema.mjs';

export class ControlRoomStack extends Stack {
  constructor(scope, id, props = {}) {
    super(scope, id, { ...props, synthesizer: new LegacyStackSynthesizer() });
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
      accountRecovery: AccountRecovery.EMAIL_ONLY,
      passwordPolicy: { minLength: 14, requireDigits: true, requireLowercase: true, requireUppercase: true, requireSymbols: true },
      removalPolicy: RemovalPolicy.RETAIN,
    });
    const client = pool.addClient('DashboardClient', {
      generateSecret: false, preventUserExistenceErrors: true,
      oAuth: { flows: { authorizationCodeGrant: true }, scopes: [OAuthScope.OPENID, OAuthScope.EMAIL], callbackUrls: [website], logoutUrls: [website] },
      accessTokenValidity: Duration.minutes(15), idTokenValidity: Duration.minutes(15), refreshTokenValidity: Duration.hours(12),
      enableTokenRevocation: true,
    });
    const domain = pool.addDomain('LoginDomain', { cognitoDomain: { domainPrefix: `iptv-control-${this.account}-${this.region}` } });
    if (props.enableRelay || props.image) {
      if (!props.githubSubject) throw Error('githubSubject is required to build the relay image.');
      let deployment;
      if (props.image) {
        if (!props.configurationPath) throw Error('relayConfig is required when relayImage is set.');
        const cfg = serverConfig.parse(JSON.parse(readFileSync(props.configurationPath, 'utf8')));
        // Only verification hashes and public trust certificates enter the deployment; never device secrets/provider passwords.
        const runtime = { ...cfg, region: 'us-east-2', userPoolId: pool.userPoolId, clientId: client.userPoolClientId, origins: [website.slice(0, -1)] };
        deployment = {
          containers: [{ containerName: 'relay', image: props.image,
            ports: [{ port: '8080', protocol: 'HTTP' }],
            environment: [{ variable: 'NODE_ENV', value: 'production' }, { variable: 'PORT', value: '8080' },
              { variable: 'CONTROL_ROOM_CONFIG_JSON', value: this.toJsonString(runtime) }] }],
          publicEndpoint: { containerName: 'relay', containerPort: 8080,
            healthCheckConfig: { path: '/health', successCodes: '200', intervalSeconds: 15, timeoutSeconds: 5, healthyThreshold: 2, unhealthyThreshold: 3 } },
        };
      }
      const service = new CfnContainer(this, 'Relay', {
        serviceName: 'iptv-control-room', power: 'nano', scale: 1, containerServiceDeployment: deployment,
      });
      const provider = new OidcProviderNative(this, 'GitHubOidc', {
        url: 'https://token.actions.githubusercontent.com', clientIds: ['sts.amazonaws.com'],
      });
      const builder = new Role(this, 'ImageBuilder', {
        roleName: 'iptv-control-room-github',
        assumedBy: new WebIdentityPrincipal(provider.openIdConnectProviderArn, {
          StringEquals: {
            'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
            'token.actions.githubusercontent.com:sub': props.githubSubject,
          },
        }),
      });
      builder.addToPolicy(new PolicyStatement({ actions: ['lightsail:RegisterContainerImage'], resources: [service.attrContainerArn] }));
      builder.addToPolicy(new PolicyStatement({ actions: [
        'lightsail:CreateContainerServiceRegistryLogin', 'lightsail:GetContainerAPIMetadata',
        'lightsail:GetContainerImages', 'lightsail:GetContainerServices',
      ], resources: ['*'] }));
      if (props.image) new CfnOutput(this, 'RelayUrl', { value: service.attrUrl });
      new CfnOutput(this, 'RelayServiceUrl', { value: service.attrUrl });
      new CfnOutput(this, 'ContainerServiceName', { value: service.ref });
      new CfnOutput(this, 'ImageBuilderRoleArn', { value: builder.roleArn });
    }
    new CfnOutput(this, 'Region', { value: this.region });
    new CfnOutput(this, 'DashboardUrl', { value: website });
    new CfnOutput(this, 'AmplifyAppId', { value: site.attrAppId });
    new CfnOutput(this, 'UserPoolId', { value: pool.userPoolId });
    new CfnOutput(this, 'ClientId', { value: client.userPoolClientId });
    new CfnOutput(this, 'LoginUrl', { value: domain.baseUrl() });
  }
}
