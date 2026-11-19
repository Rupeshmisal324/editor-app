import React, { useRef, useState } from 'react';
import {
  FlatList,
  Pressable,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import Icon, { type IconName } from '../components/Icon';
import { Colors, Fonts, Spacing } from '../theme';
import { setOnboarded } from '../storage/prefs';
import type { RootStackParamList } from '../navigation';

type Props = NativeStackScreenProps<RootStackParamList, 'Onboarding'>;

const PAGES: Array<{ icons: IconName[]; title: string; body: string }> = [
  {
    icons: ['photo', 'sparkle', 'video'],
    title: 'Edit photos and videos in one place',
    body: 'Filters, adjustments, text, stickers and drawing for photos. Trim, split, speed and music for videos.',
  },
  {
    icons: ['wand', 'edit', 'grid'],
    title: 'Change your mind any time',
    body: 'Every edit is kept in Library. Open it again to move text, swap stickers or try another filter.',
  },
  {
    icons: ['download', 'check', 'share'],
    title: 'Private by design',
    body: 'Editing happens on your phone. Nothing is uploaded unless you share it yourself.',
  },
];

const OnboardingScreen: React.FC<Props> = ({ navigation }) => {
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const [page, setPage] = useState(0);
  const listRef = useRef<FlatList>(null);
  const last = page === PAGES.length - 1;

  const finish = async () => {
    await setOnboarded(true);
    navigation.replace('Main');
  };

  const next = () => {
    if (last) finish();
    else listRef.current?.scrollToIndex({ index: page + 1, animated: true });
  };

  const onScroll = (e: NativeSyntheticEvent<NativeScrollEvent>) => {
    const index = Math.round(e.nativeEvent.contentOffset.x / width);
    if (index !== page) setPage(index);
  };

  return (
    <View style={[styles.screen, { paddingTop: insets.top, paddingBottom: insets.bottom + Spacing.lg }]}>
      <View style={styles.topRow}>
        {!last && (
          <Pressable hitSlop={12} onPress={finish} accessibilityRole="button">
            <Text style={styles.skip}>Skip</Text>
          </Pressable>
        )}
      </View>

      <FlatList
        ref={listRef}
        data={PAGES}
        keyExtractor={p => p.title}
        horizontal
        pagingEnabled
        showsHorizontalScrollIndicator={false}
        onScroll={onScroll}
        scrollEventThrottle={16}
        renderItem={({ item }) => (
          <View style={[styles.page, { width }]}>
            <View style={styles.art}>
              <View style={[styles.ring, styles.ringOuter]} />
              <View style={[styles.ring, styles.ringInner]} />
              <View style={styles.artRow}>
                <View style={styles.sideIcon}>
                  <Icon name={item.icons[0]} size={26} color={Colors.textSecondary} />
                </View>
                <View style={styles.mainIcon}>
                  <Icon name={item.icons[1]} size={44} color={Colors.onAccent} />
                </View>
                <View style={styles.sideIcon}>
                  <Icon name={item.icons[2]} size={26} color={Colors.textSecondary} />
                </View>
              </View>
            </View>
            <Text style={styles.title}>{item.title}</Text>
            <Text style={styles.body}>{item.body}</Text>
          </View>
        )}
      />

      <View style={styles.dots}>
        {PAGES.map((p, i) => (
          <View key={p.title} style={[styles.dot, i === page && styles.dotOn]} />
        ))}
      </View>

      <Pressable
        accessibilityRole="button"
        onPress={next}
        style={({ pressed }) => [styles.cta, pressed && styles.pressed]}>
        <Text style={styles.ctaText}>{last ? 'Get started' : 'Next'}</Text>
      </Pressable>
    </View>
  );
};

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: Colors.bg },
  topRow: { height: 48, alignItems: 'flex-end', justifyContent: 'center', paddingHorizontal: Spacing.page },
  skip: { fontFamily: Fonts.medium, fontSize: 15, color: Colors.textSecondary },
  page: { flex: 1, alignItems: 'center', justifyContent: 'flex-start', paddingTop: 56, paddingHorizontal: 32 },
  art: { width: 260, height: 260, alignItems: 'center', justifyContent: 'center', marginBottom: 40 },
  ring: { position: 'absolute', borderRadius: 999, borderWidth: 1, borderColor: Colors.border },
  ringOuter: { width: 260, height: 260 },
  ringInner: { width: 180, height: 180, backgroundColor: Colors.surface, borderWidth: 0 },
  artRow: { flexDirection: 'row', alignItems: 'center', gap: 18 },
  sideIcon: {
    width: 56,
    height: 56,
    borderRadius: 18,
    backgroundColor: Colors.surfaceHigh,
    alignItems: 'center',
    justifyContent: 'center',
  },
  mainIcon: {
    width: 92,
    height: 92,
    borderRadius: 28,
    backgroundColor: Colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  title: {
    fontFamily: Fonts.bold,
    fontSize: 26,
    lineHeight: 32,
    color: Colors.text,
    textAlign: 'center',
    letterSpacing: -0.3,
  },
  body: {
    fontFamily: Fonts.regular,
    fontSize: 15,
    lineHeight: 22,
    color: Colors.textSecondary,
    textAlign: 'center',
    marginTop: Spacing.md,
  },
  dots: { flexDirection: 'row', justifyContent: 'center', gap: 6, marginBottom: Spacing.xl },
  dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: Colors.dot },
  dotOn: { width: 20, backgroundColor: Colors.text },
  cta: {
    marginHorizontal: Spacing.page,
    height: 54,
    borderRadius: 16,
    backgroundColor: Colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pressed: { opacity: 0.85 },
  ctaText: { fontFamily: Fonts.semiBold, fontSize: 16, color: Colors.onAccent },
});

export default OnboardingScreen;
