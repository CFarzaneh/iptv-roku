// Cognito managed login uses this palette for its username, password, and passkey pages.
export const loginBranding = {
  categories: { global: { colorSchemeMode: 'DARK' } },
  components: {
    pageBackground: { image: { enabled: false }, darkMode: { color: '030b1dff' } },
    form: { darkMode: { backgroundColor: '0b2d58ff', borderColor: '2270adff' } },
    pageText: { darkMode: { headingColor: 'f3f8ffff', bodyColor: 'a7c1e0ff', descriptionColor: 'a7c1e0ff' } },
    primaryButton: { darkMode: {
      defaults: { backgroundColor: 'ffa21fff', textColor: '211402ff' },
      hover: { backgroundColor: 'ffc044ff', textColor: '211402ff' },
      active: { backgroundColor: 'ff8a0dff', textColor: '211402ff' },
    } },
  },
};
