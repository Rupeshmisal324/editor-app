import React, { useEffect, useState } from 'react';
import { StatusBar, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import RootNavigator from './src/navigation';
import { ToastProvider } from './src/components/Toast';
import { hasOnboarded } from './src/storage/prefs';
import { loadCreations } from './src/storage/creations';
import { Colors } from './src/theme';
import { initAds } from './src/ads/ads';
import { initPremium } from './src/purchases/premium';

const App = () => {
  // null = still reading the saved flag (a dark frame, same as the launch screen).
  const [showOnboarding, setShowOnboarding] = useState<boolean | null>(null);

  useEffect(() => {
    loadCreations();
    hasOnboarded().then(done => setShowOnboarding(!done));
    // Purchase status first, so paid users never start the ad SDK.
    initPremium().then(initAds);
  }, []);

  return (
    <SafeAreaProvider style={styles.root}>
      <StatusBar barStyle="light-content" backgroundColor="transparent" translucent />
      <ToastProvider>
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
