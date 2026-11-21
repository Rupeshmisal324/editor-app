import React, { useEffect, useState } from 'react';
import { Linking, StatusBar, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import RootNavigator from './src/navigation';
import { ToastProvider, useToast } from './src/components/Toast';
import { hasOnboarded } from './src/storage/prefs';
import { loadCreations } from './src/storage/creations';
import { Colors } from './src/theme';
import { initAds } from './src/ads/ads';
import { initPremium, redeemWebPurchaseUrl } from './src/purchases/premium';

/** Redeems a web (Stripe) purchase when its Redemption Link opens the app. */
const WebPurchaseLinks = ({ premiumReady }: { premiumReady: boolean }) => {
  const { show } = useToast(); // stable (useCallback); the context object is not
  useEffect(() => {
    if (!premiumReady) return;
    const handle = async (url: string | null) => {
      if (!url) return;
      const outcome = await redeemWebPurchaseUrl(url);
      if (outcome?.status === 'purchased') show({ message: 'Ads removed. Thank you!', icon: 'check' });
      else if (outcome?.status === 'error') show({ message: outcome.message, tone: 'error' });
    };
    Linking.getInitialURL().then(handle, () => {});
    const sub = Linking.addEventListener('url', e => handle(e.url));
    return () => sub.remove();
  }, [premiumReady, show]);
  return null;
};

const App = () => {
  // null = still reading the saved flag (a dark frame, same as the launch screen).
  const [showOnboarding, setShowOnboarding] = useState<boolean | null>(null);
  const [premiumReady, setPremiumReady] = useState(false);

  useEffect(() => {
    loadCreations();
    hasOnboarded().then(done => setShowOnboarding(!done));
    // Purchase status first, so paid users never start the ad SDK.
    initPremium().then(() => {
      setPremiumReady(true);
      initAds();
    });
  }, []);

  return (
    <SafeAreaProvider style={styles.root}>
      <StatusBar barStyle="light-content" backgroundColor="transparent" translucent />
      <ToastProvider>
        <WebPurchaseLinks premiumReady={premiumReady} />
        {showOnboarding === null ? (
          <View style={styles.root} />
        ) : (
          <RootNavigator showOnboarding={showOnboarding} />
        )}
      </ToastProvider>
    </SafeAreaProvider>
  );
};

const styles = StyleSheet.create({ root: { flex: 1, backgroundColor: Colors.bg } });

export default App;
