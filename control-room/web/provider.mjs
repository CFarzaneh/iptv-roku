export function providerErrorMessage(code, providerType) {
  const messages = {
    PROVIDER_CONNECTION_FAILED: 'The Roku could not connect to the provider. Try again shortly.',
    PROVIDER_ACCESS_DENIED: 'The provider denied access from this Roku. Check provider or network restrictions.',
    PROVIDER_ACCOUNT_REJECTED: 'The provider rejected the account. Check the username and password.',
    PROVIDER_ACCOUNT_INACTIVE: 'The provider reports that this account is inactive. Contact the provider.',
    PROVIDER_BAD_RESPONSE: 'The provider returned an unexpected response. Check the server address or try again shortly.',
    PROVIDER_ERROR: providerType === 'm3u'
      ? 'The Roku could not load channels from this playlist URL. Enter the complete M3U URL.'
      : 'The Roku could not validate this account. Check the server address or try again shortly.',
  };
  return messages[code];
}
