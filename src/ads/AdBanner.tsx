import React, { useEffect, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { BannerAd, BannerAdSize } from 'react-native-google-mobile-ads';
import { adsReady, bannerUnitId, subscribeAdsReady } from './ads';
import { Colors } from '../theme';

type Props = {
  /** Reports the space the banner takes (0 until an ad has loaded). */
  onHeight?: (height: number) => void;
};

/** Anchored adaptive banner; takes no space until an ad actually loads. */
const AdBanner: React.FC<Props> = ({ onHeight }) => {
  const [ready, setReady] = useState(adsReady());
  const [loaded, setLoaded] = useState(false);

  useEffect(() => subscribeAdsReady(setReady), []);
  // Ads switched off (Remove ads bought): give the space back.
  useEffect(() => {
    if (!ready) {
      setLoaded(false);
      onHeight?.(0);
    }
  }, [ready, onHeight]);

  const unitId = bannerUnitId();
  if (!ready || !unitId) return null;

  return (
    <View
      style={[styles.wrap, !loaded && styles.collapsed]}
      onLayout={e => onHeight?.(loaded ? e.nativeEvent.layout.height : 0)}>
      <BannerAd
        unitId={unitId}
        size={BannerAdSize.ANCHORED_ADAPTIVE_BANNER}
        onAdLoaded={() => setLoaded(true)}
        onAdFailedToLoad={() => {
          setLoaded(false);
          onHeight?.(0);
        }}
      />
    </View>
  );
};

const styles = StyleSheet.create({
  wrap: {
    alignItems: 'center',
    backgroundColor: Colors.bg,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: Colors.border,
  },
  // Keep it mounted (so it can load) but invisible and space-free until then.
  collapsed: { height: 0, overflow: 'hidden', borderTopWidth: 0 },
});

export default AdBanner;
