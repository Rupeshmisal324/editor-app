import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import {
  NativeAd,
  NativeAdView,
  NativeAsset,
  NativeAssetType,
  NativeMediaView,
} from 'react-native-google-mobile-ads';
import { Colors, Fonts, Radius, Spacing } from '../theme';

/**
 * Full-width sponsored card shown between Library grid rows.
 * Media is 120x120 (AdMob's minimum for native media); clicks are handled by
 * the SDK through the registered assets, so no Pressable here.
 */
const NativeAdCard: React.FC<{ ad: NativeAd }> = ({ ad }) => (
  <NativeAdView nativeAd={ad} style={styles.card}>
    <NativeMediaView style={styles.media} resizeMode="cover" />
    <View style={styles.info}>
      <View style={styles.topRow}>
        <View style={styles.badge}>
          <Text style={styles.badgeText}>Ad</Text>
        </View>
        {!!ad.advertiser && (
          <NativeAsset assetType={NativeAssetType.ADVERTISER}>
            <Text style={styles.advertiser} numberOfLines={1}>
              {ad.advertiser}
            </Text>
          </NativeAsset>
        )}
      </View>
      <NativeAsset assetType={NativeAssetType.HEADLINE}>
        <Text style={styles.headline} numberOfLines={2}>
          {ad.headline}
        </Text>
      </NativeAsset>
      {!!ad.body && (
        <NativeAsset assetType={NativeAssetType.BODY}>
          <Text style={styles.body} numberOfLines={1}>
            {ad.body}
          </Text>
        </NativeAsset>
      )}
      {!!ad.callToAction && (
        <NativeAsset assetType={NativeAssetType.CALL_TO_ACTION}>
          <Text style={styles.cta} numberOfLines={1}>
            {ad.callToAction}
          </Text>
        </NativeAsset>
      )}
    </View>
  </NativeAdView>
);

const styles = StyleSheet.create({
  card: {
    flexDirection: 'row',
    marginHorizontal: Spacing.md,
    marginVertical: Spacing.sm,
    padding: Spacing.sm,
    gap: Spacing.md,
    borderRadius: Radius.md,
    backgroundColor: Colors.surface,
  },
  media: { width: 120, height: 120, borderRadius: Radius.sm, overflow: 'hidden' },
  info: { flex: 1, justifyContent: 'space-between' },
  topRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.sm },
  badge: {
    paddingHorizontal: 6,
    paddingVertical: 1,
    borderRadius: 4,
    backgroundColor: Colors.surfaceHigh,
  },
  badgeText: { fontFamily: Fonts.semiBold, fontSize: 11, color: Colors.textSecondary },
  advertiser: { flex: 1, fontFamily: Fonts.medium, fontSize: 12, color: Colors.textMuted },
  headline: { fontFamily: Fonts.semiBold, fontSize: 15, color: Colors.text },
  body: { fontFamily: Fonts.regular, fontSize: 13, color: Colors.textSecondary },
  cta: {
    alignSelf: 'flex-start',
    overflow: 'hidden',
    paddingHorizontal: Spacing.md,
    paddingVertical: 7,
    borderRadius: Radius.pill,
    backgroundColor: Colors.accent,
    color: Colors.onAccent,
    fontFamily: Fonts.semiBold,
    fontSize: 13,
  },
});

export default NativeAdCard;
