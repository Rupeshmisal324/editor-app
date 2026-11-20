import React, { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Linking,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import Icon from '../components/Icon';
import { Colors, Fonts, Radius, Spacing, Type } from '../theme';
import { AppConfig } from '../config';
import AdBanner from '../ads/AdBanner';
import { privacyOptionsRequired, showPrivacyOptions } from '../ads/ads';
import { useToast } from '../components/Toast';
import {
  buyRemoveAds,
  getRemoveAdsPrice,
  isAdsRemoved,
  purchasesEnabled,
  restoreRemoveAds,
  subscribeAdsRemoved,
} from '../purchases/premium';
import {
  creationsSizeBytes,
  deleteAllCreations,
  loadCreations,
  subscribeCreations,
} from '../storage/creations';
import { setOnboarded } from '../storage/prefs';
import type { RootStackParamList } from '../navigation';

type Props = NativeStackScreenProps<RootStackParamList, 'Settings'>;

const formatBytes = (bytes: number) => {
  if (bytes < 1024 * 1024) return `${Math.max(0, Math.round(bytes / 1024))} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
};

const SettingsScreen: React.FC<Props> = ({ navigation }) => {
  const insets = useSafeAreaInsets();
  const [count, setCount] = useState(0);
  const [size, setSize] = useState(0);
  const toast = useToast();
  const [adsRemoved, setAdsRemoved] = useState(isAdsRemoved());
  const [price, setPrice] = useState<string | null>(null);
  const [buying, setBuying] = useState(false);
  const [showAdPrivacy, setShowAdPrivacy] = useState(false);

  useEffect(() => {
    privacyOptionsRequired().then(setShowAdPrivacy);
  }, []);

  useEffect(() => subscribeAdsRemoved(setAdsRemoved), []);
  useEffect(() => {
    if (purchasesEnabled && !adsRemoved) getRemoveAdsPrice().then(setPrice);
  }, [adsRemoved]);

  const buy = async () => {
    if (buying) return;
    setBuying(true);
    const outcome = await buyRemoveAds();
    setBuying(false);
    if (outcome.status === 'purchased') toast.show({ message: 'Ads removed. Thank you!', icon: 'check' });
    else if (outcome.status === 'error') toast.show({ message: outcome.message, tone: 'error' });
  };

  const restore = async () => {
    if (buying) return;
    setBuying(true);
    const removed = await restoreRemoveAds();
    setBuying(false);
    toast.show(
      removed
        ? { message: 'Purchase restored. Ads removed.', icon: 'check' }
        : { message: 'No purchase found for this account.', tone: 'error' },
    );
  };

  const refresh = useCallback(async () => {
    const list = await loadCreations();
    setCount(list.length);
    setSize(await creationsSizeBytes());
  }, []);

  useEffect(() => {
    refresh();
    return subscribeCreations(() => {
      refresh();
    });
  }, [refresh]);

  const clearAll = () => {
    if (count === 0) return;
    Alert.alert(
      'Clear Library?',
      'All edits kept in the app are removed. Copies saved to your photos are kept.',
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Clear', style: 'destructive', onPress: () => deleteAllCreations() },
      ],
    );
  };

  const open = (url: string) => {
    if (!url) return;
    Linking.openURL(url).catch(() => {});
  };

  const rateUrl =
    Platform.OS === 'ios'
      ? AppConfig.appStoreId
        ? `itms-apps://apps.apple.com/app/id${AppConfig.appStoreId}?action=write-review`
        : ''
      : `market://details?id=${AppConfig.androidPackage}`;

  return (
    <View style={styles.screen}>
      <View style={[styles.topBar, { paddingTop: insets.top + Spacing.sm }]}>
        <Pressable
          accessibilityLabel="Back"
          hitSlop={10}
          onPress={() => navigation.goBack()}
          style={styles.roundButton}>
          <Icon name="back" />
        </Pressable>
        <Text style={Type.heading}>Settings</Text>
        <View style={styles.roundButtonSpacer} />
      </View>

      <ScrollView contentContainerStyle={{ paddingBottom: Spacing.xxl }}>
        {purchasesEnabled && (
          <>
            <Text style={styles.groupLabel}>PREMIUM</Text>
            <View style={styles.group}>
              {adsRemoved ? (
                <Row label="Ads removed" value="Purchased" />
              ) : (
                <Row
                  label="Remove ads"
                  value={buying ? '…' : price ?? undefined}
                  chevron
                  disabled={buying}
                  onPress={buy}
                />
              )}
              <Row label="Restore purchases" chevron disabled={buying} onPress={restore} />
            </View>
          </>
        )}

        <Text style={styles.groupLabel}>STORAGE</Text>
        <View style={styles.group}>
          <Row label="Library" value={`${count} ${count === 1 ? 'item' : 'items'} · ${formatBytes(size)}`} />
          <Row label="Clear Library" danger onPress={clearAll} disabled={count === 0} />
        </View>

        <Text style={styles.groupLabel}>SUPPORT</Text>
        <View style={styles.group}>
          <Row
            label="Show the intro again"
            chevron
            onPress={async () => {
              await setOnboarded(false);
              navigation.reset({ index: 0, routes: [{ name: 'Onboarding' }] });
            }}
          />
          {!!rateUrl && <Row label="Rate Editor" chevron onPress={() => open(rateUrl)} />}
          {!!AppConfig.supportEmail && (
            <Row
              label="Contact us"
              chevron
              onPress={() => open(`mailto:${AppConfig.supportEmail}?subject=Editor%20support`)}
            />
          )}
          {!!AppConfig.privacyPolicyUrl && (
            <Row label="Privacy policy" chevron onPress={() => open(AppConfig.privacyPolicyUrl)} />
          )}
          {showAdPrivacy && <Row label="Privacy options" chevron onPress={showPrivacyOptions} />}
          {!!AppConfig.termsUrl && (
            <Row label="Terms of use" chevron onPress={() => open(AppConfig.termsUrl)} />
          )}
          <Row label="Version" value={AppConfig.version} />
        </View>

        <Text style={[Type.caption, styles.footer]}>
          Your photos and videos are edited on this device and never uploaded.
        </Text>
      </ScrollView>

      <View style={{ paddingBottom: insets.bottom }}>
        <AdBanner />
      </View>
    </View>
  );
};

const Row: React.FC<{
  label: string;
  value?: string;
  chevron?: boolean;
  danger?: boolean;
  disabled?: boolean;
  onPress?: () => void;
}> = ({ label, value, chevron, danger, disabled, onPress }) => (
  <Pressable
    disabled={!onPress || disabled}
    onPress={onPress}
    style={({ pressed }) => [styles.row, pressed && styles.rowPressed, disabled && styles.disabled]}>
    <Text style={[styles.rowLabel, danger && styles.danger]}>{label}</Text>
    {!!value && <Text style={Type.body}>{value}</Text>}
    {chevron && <Icon name="chevron" size={18} color={Colors.textMuted} />}
  </Pressable>
);

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: Colors.bg },
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.md,
  },
  roundButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  roundButtonSpacer: { width: 44 },
  groupLabel: {
    fontFamily: Fonts.semiBold,
    fontSize: 11,
    letterSpacing: 0.7,
    color: Colors.textMuted,
    marginTop: Spacing.xxl,
    marginBottom: Spacing.sm,
    marginHorizontal: Spacing.page + Spacing.xs,
  },
  group: {
    marginHorizontal: Spacing.lg,
    borderRadius: Radius.md,
    backgroundColor: Colors.surface,
    overflow: 'hidden',
    gap: StyleSheet.hairlineWidth,
  },
  row: {
    minHeight: 54,
    paddingHorizontal: Spacing.lg,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: Colors.surface,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: Colors.border,
  },
  rowPressed: { backgroundColor: Colors.surfacePress },
  rowLabel: { fontFamily: Fonts.regular, fontSize: 15, color: Colors.text },
  danger: { color: Colors.danger },
  disabled: { opacity: 0.45 },
  footer: { textAlign: 'center', marginTop: Spacing.xxl, marginHorizontal: 40 },
});

export default SettingsScreen;
