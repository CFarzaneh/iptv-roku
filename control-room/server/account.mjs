import {
  CognitoIdentityProviderClient, GetUserCommand, UpdateUserAttributesCommand,
  VerifyUserAttributeCommand, GetUserAttributeVerificationCodeCommand,
  ListWebAuthnCredentialsCommand, DeleteWebAuthnCredentialCommand,
} from '@aws-sdk/client-cognito-identity-provider';

export function accountService(region) {
  const client = new CognitoIdentityProviderClient({ region });
  const send = (Command, input) => client.send(new Command(input));
  return {
    async view(token) {
      const [user, firstPage] = await Promise.all([
        send(GetUserCommand, { AccessToken: token }),
        send(ListWebAuthnCredentialsCommand, { AccessToken: token, MaxResults: 20 }),
      ]);
      const credentials = [...(firstPage.Credentials || [])];
      let nextToken = firstPage.NextToken;
      while (nextToken && credentials.length < 100) {
        const page = await send(ListWebAuthnCredentialsCommand, { AccessToken: token, MaxResults: 20, NextToken: nextToken });
        credentials.push(...(page.Credentials || []));
        nextToken = page.NextToken;
      }
      const attributes = Object.fromEntries((user.UserAttributes || []).map(({ Name, Value }) => [Name, Value]));
      return { email: attributes.email || '', emailVerified: attributes.email_verified === 'true',
        passkeys: credentials.map(({ CredentialId, FriendlyCredentialName, CreatedAt }) => ({
          id: CredentialId, name: FriendlyCredentialName, createdAt: CreatedAt,
        })) };
    },
    updateEmail: (token, email) => send(UpdateUserAttributesCommand, {
      AccessToken: token, UserAttributes: [{ Name: 'email', Value: email }],
    }),
    verifyEmail: (token, code) => send(VerifyUserAttributeCommand, {
      AccessToken: token, AttributeName: 'email', Code: code,
    }),
    resendEmailCode: token => send(GetUserAttributeVerificationCodeCommand, {
      AccessToken: token, AttributeName: 'email',
    }),
    deletePasskey: (token, credentialId) => send(DeleteWebAuthnCredentialCommand, {
      AccessToken: token, CredentialId: credentialId,
    }),
  };
}
