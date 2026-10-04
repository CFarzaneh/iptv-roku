// Cognito managed login uses this palette for its username, password, and passkey pages.
export const loginBranding = {
  categories: { global: { colorSchemeMode: 'DARK' } },
  components: {
    pageBackground: { image: { enabled: false }, darkMode: { color: '071120ff' } },
    form: { darkMode: { backgroundColor: '0d1b30ff', borderColor: '25405fff' } },
    pageText: { darkMode: { headingColor: 'e8f0ffff', bodyColor: '91a7c2ff', descriptionColor: '91a7c2ff' } },
    primaryButton: { darkMode: {
      defaults: { backgroundColor: 'ff9a42ff', textColor: '1d180fff' },
      hover: { backgroundColor: 'ffb56cff', textColor: '1d180fff' },
      active: { backgroundColor: 'f58b32ff', textColor: '1d180fff' },
    } },
  },
};
