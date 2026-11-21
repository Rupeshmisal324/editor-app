/**
 * Store / support details. Fill these in before release.
 * TODO(release): set the real privacy policy URL, support email and store ids.
 */
export const AppConfig = {
  name: 'Editor',
  version: '1.0.0',
  privacyPolicyUrl: '',
  termsUrl: '',
  supportEmail: '',
  /** App Store numeric id, e.g. '1234567890' (for "Rate Editor"). */
  appStoreId: '',
  androidPackage: 'com.editorapp.editor',
  /**
   * RevenueCat public SDK keys ("Remove ads" purchase). Empty = purchases off
   * and the Settings rows stay hidden. iOS key starts "appl_", Android "goog_".
   */
  revenueCatIosKey: '',
  revenueCatAndroidKey: '',
  /**
   * Stripe web checkout through RevenueCat Web Billing: the Web Purchase Link
   * from the RevenueCat dashboard (https://pay.rev.cat/...), with Redemption
   * Links turned on. Empty = no "Buy on the web" row. Shown only on iPhone in
   * these App Store countries (Apple allows outside purchase links there).
   */
  webCheckoutUrl: '',
  webCheckoutCountries: ['USA'],
};
