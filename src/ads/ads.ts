import mobileAds, {
  AdEventType,
  AdsConsent,
  InterstitialAd,
  NativeAd,
  TestIds,
} from 'react-native-google-mobile-ads';
import { isAdsRemoved, subscribeAdsRemoved } from '../purchases/premium';

/**
 * Google AdMob (react-native-google-mobile-ads).
 *
 * TEST MODE: `USE_TEST_ADS = true` uses Google's sample ad units, which are
 * always safe to tap. Before release: set real unit ids below, set this to
 * false, and replace the test app ids in app.json.
 */
const USE_TEST_ADS = true;

const UNITS = {
  banner: USE_TEST_ADS ? TestIds.ADAPTIVE_BANNER : '',
  interstitial: USE_TEST_ADS ? TestIds.INTERSTITIAL : '',
  native: USE_TEST_ADS ? TestIds.NATIVE : '',
};

/**
 * Full-screen ad after every Nth "moment" (new edit, edit again, save to
 * Photos, share), never twice within the cooldown (e.g. edit then save right away).
 */
const INTERSTITIAL_EVERY = 3;
const INTERSTITIAL_COOLDOWN_MS = 60_000;

let ready = false;
const readyListeners = new Set<(r: boolean) => void>();
let interstitial: InterstitialAd | null = null;
let interstitialLoaded = false;
let momentsSinceAd = 0;
let lastShownAt = 0;

export const bannerUnitId = () => UNITS.banner;
export const adsReady = () => ready;
export const subscribeAdsReady = (fn: (r: boolean) => void) => {
  readyListeners.add(fn);
  return () => {
    readyListeners.delete(fn);
  };
};

/**
 * Consent first (Google UMP form; shows only where required, e.g. EU/UK, and
 * includes the iOS tracking prompt when set up in AdMob), then start the SDK.
 * Never throws; with no consent the app simply runs without ads.
 */
let started = false;
export const initAds = async () => {
  if (started || isAdsRemoved()) return;
  started = true;
  try {
    await AdsConsent.gatherConsent();
  } catch {
    // No consent form configured / offline: fall through to canRequestAds.
  }
  let canRequest = false;
  try {
    canRequest = (await AdsConsent.getConsentInfo()).canRequestAds;
  } catch {}
  // Test ads carry no personal data, so allow them even when the consent form
  // could not load (the test app id has no consent message set up).
  if (!canRequest && !USE_TEST_ADS) return;

  try {
    await mobileAds().initialize();
  } catch {
    return;
  }
  if (isAdsRemoved()) return; // bought while the SDK was starting
  ready = true;
  readyListeners.forEach(fn => fn(true));
  loadInterstitial();
};

/** "Remove ads" bought (or restored): hide every ad right away. */
subscribeAdsRemoved(removed => {
  if (!removed || !ready) return;
  ready = false;
  interstitial = null;
  interstitialLoaded = false;
  readyListeners.forEach(fn => fn(false));
});

const loadInterstitial = () => {
  if (!UNITS.interstitial) return;
  interstitialLoaded = false;
  const ad = InterstitialAd.createForAdRequest(UNITS.interstitial);
  ad.addAdEventListener(AdEventType.LOADED, () => {
    interstitialLoaded = true;
  });
  ad.addAdEventListener(AdEventType.CLOSED, () => {
    if (ready) loadInterstitial(); // preload the next one
  });
  ad.addAdEventListener(AdEventType.ERROR, () => {
    interstitialLoaded = false;
  });
  interstitial = ad;
  ad.load();
};

/** Call at a natural break. Shows an ad only if one is ready and due. */
export const maybeShowInterstitial = () => {
  momentsSinceAd += 1;
  if (!ready || !interstitial || !interstitialLoaded) return;
  if (momentsSinceAd < INTERSTITIAL_EVERY) return;
  if (Date.now() - lastShownAt < INTERSTITIAL_COOLDOWN_MS) return;
  momentsSinceAd = 0;
  lastShownAt = Date.now();
  interstitialLoaded = false;
  interstitial.show().catch(() => loadInterstitial());
};

/** One native ad for the Library card; null when ads are off or none filled. */
export const loadNativeAd = async (): Promise<NativeAd | null> => {
  if (!ready || !UNITS.native) return null;
  try {
    return await NativeAd.createForAdRequest(UNITS.native);
  } catch {
    return null;
  }
};
