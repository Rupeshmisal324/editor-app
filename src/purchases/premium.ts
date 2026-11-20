import { Platform } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import Purchases, { type CustomerInfo } from 'react-native-purchases';
import { AppConfig } from '../config';

/**
 * "Remove ads" one-time purchase through RevenueCat.
 *
 * Store setup (both stores): a non-consumable / one-time product with id
 * PRODUCT_ID. RevenueCat: attach that product to an entitlement ENTITLEMENT.
 */
export const PRODUCT_ID = 'remove_ads';
const ENTITLEMENT = 'no_ads';
/** Last known answer, so paid users never see an ad flash at launch or offline. */
const CACHE_KEY = 'editor.adsRemoved.v1';

const apiKey = Platform.OS === 'ios' ? AppConfig.revenueCatIosKey : AppConfig.revenueCatAndroidKey;
export const purchasesEnabled = !!apiKey;

let adsRemoved = false;
let configured = false;
const listeners = new Set<(removed: boolean) => void>();

export const isAdsRemoved = () => adsRemoved;
export const subscribeAdsRemoved = (fn: (removed: boolean) => void) => {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
};

const setRemoved = (removed: boolean) => {
  if (removed === adsRemoved) return;
  adsRemoved = removed;
  AsyncStorage.setItem(CACHE_KEY, removed ? '1' : '0').catch(() => {});
  listeners.forEach(fn => fn(removed));
};

const apply = (info: CustomerInfo) => setRemoved(!!info.entitlements.active[ENTITLEMENT]);

/**
 * Reads the cached answer first (fast, offline), then asks RevenueCat.
 * Resolves once the cached answer is known; the network check continues.
 */
export const initPremium = async () => {
  try {
    adsRemoved = (await AsyncStorage.getItem(CACHE_KEY)) === '1';
  } catch {}
  if (!purchasesEnabled) return;
  try {
    Purchases.configure({ apiKey });
    configured = true;
    Purchases.addCustomerInfoUpdateListener(apply);
    Purchases.getCustomerInfo().then(apply, () => {});
  } catch {
    configured = false;
  }
};

/** Store price, e.g. "$2.99"; null if the product can't be loaded. */
export const getRemoveAdsPrice = async (): Promise<string | null> => {
  if (!configured) return null;
  try {
    const [product] = await Purchases.getProducts(
      [PRODUCT_ID],
      Purchases.PRODUCT_CATEGORY.NON_SUBSCRIPTION,
    );
    return product?.priceString ?? null;
  } catch {
    return null;
  }
};

export type PurchaseOutcome =
  | { status: 'purchased' }
  | { status: 'cancelled' }
  | { status: 'error'; message: string };

export const buyRemoveAds = async (): Promise<PurchaseOutcome> => {
  if (!configured) return { status: 'error', message: 'Purchases are not available.' };
  try {
    const [product] = await Purchases.getProducts(
      [PRODUCT_ID],
      Purchases.PRODUCT_CATEGORY.NON_SUBSCRIPTION,
    );
    if (!product) return { status: 'error', message: 'This item is not available right now.' };
    const { customerInfo } = await Purchases.purchaseStoreProduct(product);
    apply(customerInfo);
    return adsRemoved
      ? { status: 'purchased' }
      : { status: 'error', message: 'Purchase is pending. Ads will go once it completes.' };
  } catch (e: any) {
    if (e?.userCancelled) return { status: 'cancelled' };
    return { status: 'error', message: e?.message || 'Purchase failed. Please try again.' };
  }
};

/** Restores on a new phone / reinstall. Resolves true if ads are now removed. */
export const restoreRemoveAds = async (): Promise<boolean> => {
  if (!configured) return false;
  try {
    apply(await Purchases.restorePurchases());
  } catch {}
  return adsRemoved;
};
