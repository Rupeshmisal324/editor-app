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
};
