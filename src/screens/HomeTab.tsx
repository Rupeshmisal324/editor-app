import React, { useEffect, useState } from 'react';
import { FlatList, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Icon, { type IconName } from '../components/Icon';
import MediaTile from '../components/MediaTile';
import { Colors, Fonts, Radius, Spacing, Type } from '../theme';
import { loadCreations, subscribeCreations, type Creation } from '../storage/creations';
import type { MediaType } from '../native/MediaEditor/types';
import type { EditSource } from '../media/useEditFlow';

type Props = {
  bottomSpace: number;
  onStart: (type: MediaType, source: EditSource) => void;
  onOpen: (id: string) => void;
  onSeeAll: () => void;
  onSettings: () => void;
};

const RECENT_LIMIT = 12;

/** Tools the editors really have; each card opens the matching editor. */
const TOOLS: Array<{ title: string; detail: string; type: MediaType }> = [
  { title: 'Filters & looks', detail: 'Filters, tune, blur', type: 'image' },
  { title: 'Trim & speed', detail: 'Split, 0.25x – 4x per part', type: 'video' },
];

const greeting = () => {
  const hour = new Date().getHours();
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
};

const HomeTab: React.FC<Props> = ({ bottomSpace, onStart, onOpen, onSeeAll, onSettings }) => {
  const insets = useSafeAreaInsets();
  const [creations, setCreations] = useState<Creation[]>([]);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    const unsubscribe = subscribeCreations(setCreations);
    loadCreations().then(list => {
      setCreations(list);
      setLoaded(true);
    });
    return unsubscribe;
  }, []);

  const recent = creations.slice(0, RECENT_LIMIT);

  return (
    <ScrollView
      style={styles.screen}
      contentContainerStyle={{ paddingTop: insets.top + Spacing.md, paddingBottom: bottomSpace + Spacing.xxl }}
      showsVerticalScrollIndicator={false}>
      {/* Header */}
      <View style={styles.header}>
        <View>
          <Text style={Type.caption}>{greeting()}</Text>
          <Text style={styles.brand}>Editor</Text>
        </View>
        <Pressable
          accessibilityLabel="Settings"
          hitSlop={10}
          onPress={onSettings}
          style={({ pressed }) => [styles.iconButton, pressed && styles.pressed]}>
          <Icon name="settings" size={20} />
        </Pressable>
      </View>

      {/* Primary actions */}
      <View style={styles.hero}>
        <Text style={styles.heroTitle}>What are you editing today?</Text>
        <View style={styles.heroRow}>
          <BigAction icon="photo" label="Photo" primary onPress={() => onStart('image', 'library')} />
          <BigAction icon="video" label="Video" onPress={() => onStart('video', 'library')} />
        </View>
        <View style={styles.cameraRow}>
          <Pressable
            accessibilityRole="button"
            onPress={() => onStart('image', 'camera')}
            style={({ pressed }) => [styles.cameraButton, pressed && styles.pressedBg]}>
            <Icon name="camera" size={18} color={Colors.textSecondary} />
            <Text style={styles.cameraText}>Take photo</Text>
          </Pressable>
          <View style={styles.cameraDivider} />
          <Pressable
            accessibilityRole="button"
            onPress={() => onStart('video', 'camera')}
            style={({ pressed }) => [styles.cameraButton, pressed && styles.pressedBg]}>
            <Icon name="video" size={18} color={Colors.textSecondary} />
            <Text style={styles.cameraText}>Record video</Text>
          </Pressable>
        </View>
      </View>

      {/* Recent work */}
      {loaded && recent.length > 0 && (
        <>
          <SectionHeader title="Recent" action="See all" onAction={onSeeAll} />
          <FlatList
            horizontal
            data={recent}
            keyExtractor={c => c.id}
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.recentList}
            renderItem={({ item }) => (
              <MediaTile item={item} width={112} height={148} radius={Radius.md} onPress={c => onOpen(c.id)} />
            )}
          />
        </>
      )}

      {/* First run: how it works */}
      {loaded && recent.length === 0 && (
        <>
          <SectionHeader title="How it works" />
          <View style={styles.steps}>
            {[
              ['1', 'Pick a photo or video', 'From your gallery or the camera.'],
              ['2', 'Edit it your way', 'Filters, text, stickers, trim, speed, music.'],
              ['3', 'Save or share', 'Your edits stay in Library to change later.'],
            ].map(([n, title, detail]) => (
              <View key={n} style={styles.step}>
                <View style={styles.stepNumber}>
                  <Text style={styles.stepNumberText}>{n}</Text>
                </View>
                <View style={styles.stepBody}>
                  <Text style={styles.stepTitle}>{title}</Text>
                  <Text style={Type.caption}>{detail}</Text>
                </View>
              </View>
            ))}
          </View>
        </>
      )}

      {/* Tools */}
      <SectionHeader title="Tools" />
      <View style={styles.tools}>
        {TOOLS.map(tool => (
          <Pressable
            key={tool.title}
            accessibilityRole="button"
            accessibilityLabel={`${tool.title}. Opens the ${tool.type === 'video' ? 'video' : 'photo'} editor`}
            onPress={() => onStart(tool.type, 'library')}
            style={({ pressed }) => [styles.tool, pressed && styles.pressedBg]}>
            <Text style={styles.toolTitle}>{tool.title}</Text>
            <Text style={Type.caption} numberOfLines={2}>
              {tool.detail}
            </Text>
          </Pressable>
        ))}
      </View>
    </ScrollView>
  );
};

const BigAction: React.FC<{ icon: IconName; label: string; primary?: boolean; onPress: () => void }> = ({
  icon,
  label,
  primary,
  onPress,
}) => (
  <Pressable
    accessibilityRole="button"
    accessibilityLabel={`Edit a ${label.toLowerCase()}`}
    onPress={onPress}
    style={({ pressed }) => [styles.bigAction, primary && styles.bigActionPrimary, pressed && styles.pressed]}>
    <Icon name={icon} size={26} color={primary ? Colors.onAccent : Colors.text} />
    <Text style={[styles.bigActionLabel, primary && styles.bigActionLabelPrimary]}>{label}</Text>
  </Pressable>
);

const SectionHeader: React.FC<{ title: string; action?: string; onAction?: () => void }> = ({
  title,
  action,
  onAction,
}) => (
  <View style={styles.sectionHeader}>
    <Text style={Type.heading}>{title}</Text>
    {action && (
      <Pressable hitSlop={10} onPress={onAction} accessibilityRole="button">
        <Text style={styles.sectionAction}>{action}</Text>
      </Pressable>
    )}
  </View>
);

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: Colors.bg },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.page,
  },
  brand: { fontFamily: Fonts.bold, fontSize: 28, color: Colors.text, letterSpacing: -0.5, marginTop: 2 },
  iconButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  pressed: { opacity: 0.8 },
  pressedBg: { backgroundColor: Colors.surfacePress },
  hero: {
    marginHorizontal: Spacing.lg,
    marginTop: Spacing.xl,
    padding: Spacing.lg,
    borderRadius: 24,
    backgroundColor: Colors.surface,
    borderWidth: 1,
    borderColor: Colors.heroBorder,
  },
  heroTitle: { fontFamily: Fonts.semiBold, fontSize: 20, color: Colors.text, marginBottom: Spacing.lg },
  heroRow: { flexDirection: 'row', gap: Spacing.md },
  bigAction: {
    flex: 1,
    height: 108,
    borderRadius: 18,
    backgroundColor: Colors.surfaceHigh,
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.sm,
  },
  bigActionPrimary: { backgroundColor: Colors.accent },
  bigActionLabel: { fontFamily: Fonts.semiBold, fontSize: 16, color: Colors.text },
  bigActionLabelPrimary: { color: Colors.onAccent },
  cameraRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: Spacing.md,
    borderRadius: Radius.md,
    backgroundColor: Colors.surfaceHigh,
    overflow: 'hidden',
  },
  cameraButton: {
    flex: 1,
    height: 48,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.sm,
  },
  cameraDivider: { width: StyleSheet.hairlineWidth, height: 24, backgroundColor: Colors.border },
  cameraText: { fontFamily: Fonts.medium, fontSize: 14, color: Colors.text },
  sectionHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.page,
    marginTop: 28,
    marginBottom: Spacing.md,
  },
  sectionAction: { fontFamily: Fonts.medium, fontSize: 14, color: Colors.textSecondary },
  recentList: { paddingHorizontal: Spacing.lg, gap: Spacing.sm },
  steps: { marginHorizontal: Spacing.lg, gap: Spacing.sm },
  step: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.md,
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    padding: Spacing.md,
  },
  stepNumber: {
    width: 32,
    height: 32,
    borderRadius: 16,
    backgroundColor: Colors.surfaceHigh,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepNumberText: { fontFamily: Fonts.semiBold, fontSize: 14, color: Colors.text },
  stepBody: { flex: 1 },
  stepTitle: { fontFamily: Fonts.medium, fontSize: 15, color: Colors.text, marginBottom: 2 },
  tools: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.md,
    paddingHorizontal: Spacing.lg,
  },
  tool: {
    width: '47.5%',
    flexGrow: 1,
    backgroundColor: Colors.surface,
    borderRadius: Radius.md,
    padding: 14,
  },
  toolTitle: { fontFamily: Fonts.semiBold, fontSize: 15, color: Colors.text, marginBottom: 2 },
});

export default HomeTab;
