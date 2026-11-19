import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  SectionList,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Icon, { type IconName } from '../components/Icon';
import MediaTile from '../components/MediaTile';
import { useToast } from '../components/Toast';
import { Colors, Fonts, Radius, Spacing, Type } from '../theme';
import {
  creationUri,
  dateGroupTitle,
  deleteCreations,
  loadCreations,
  subscribeCreations,
  type Creation,
} from '../storage/creations';
import { saveToPhotos, shareMany } from '../media/exportMedia';

export type LibrarySelection = { count: number; cancel: () => void };

type Props = {
  active: boolean;
  bottomSpace: number;
  onOpen: (id: string) => void;
  onCreate: () => void;
  onSelectionChange: (selection: LibrarySelection | null) => void;
};

type Filter = 'all' | 'image' | 'video';

const COLUMNS = 3;
const GAP = 3;

const LibraryTab: React.FC<Props> = ({ active, bottomSpace, onOpen, onCreate, onSelectionChange }) => {
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const toast = useToast();
  const [creations, setCreations] = useState<Creation[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [filter, setFilter] = useState<Filter>('all');
  const [selecting, setSelecting] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [working, setWorking] = useState(false);

  useEffect(() => {
    const unsubscribe = subscribeCreations(setCreations);
    loadCreations().then(list => {
      setCreations(list);
      setLoaded(true);
    });
    return unsubscribe;
  }, []);

  const cancelSelect = useCallback(() => {
    setSelecting(false);
    setSelected(new Set());
  }, []);

  // Leaving the tab ends select mode.
  useEffect(() => {
    if (!active) cancelSelect();
  }, [active, cancelSelect]);

  useEffect(() => {
    onSelectionChange(selecting ? { count: selected.size, cancel: cancelSelect } : null);
  }, [cancelSelect, onSelectionChange, selected.size, selecting]);

  const counts = useMemo(
    () => ({
      all: creations.length,
      image: creations.filter(c => c.type === 'image').length,
      video: creations.filter(c => c.type === 'video').length,
    }),
    [creations],
  );

  const sections = useMemo(() => {
    const visible = filter === 'all' ? creations : creations.filter(c => c.type === filter);
    const groups: Array<{ title: string; data: Creation[][] }> = [];
    let current: { title: string; items: Creation[] } | null = null;
    const flush = () => {
      if (!current) return;
      const rows: Creation[][] = [];
      for (let i = 0; i < current.items.length; i += COLUMNS) rows.push(current.items.slice(i, i + COLUMNS));
      groups.push({ title: current.title, data: rows });
    };
    for (const item of visible) {
      const title = dateGroupTitle(item.createdAt);
      if (!current || current.title !== title) {
        flush();
        current = { title, items: [] };
      }
      current.items.push(item);
    }
    flush();
    return groups;
  }, [creations, filter]);

  const toggle = useCallback((item: Creation) => {
    setSelected(prev => {
      const next = new Set(prev);
      if (next.has(item.id)) next.delete(item.id);
      else next.add(item.id);
      return next;
    });
  }, []);

  const onTilePress = useCallback(
    (item: Creation) => (selecting ? toggle(item) : onOpen(item.id)),
    [onOpen, selecting, toggle],
  );

  const onTileLongPress = useCallback(
    (item: Creation) => {
      setSelecting(true);
      toggle(item);
    },
    [toggle],
  );

  const selectedItems = creations.filter(c => selected.has(c.id));

  const saveSelected = async () => {
    setWorking(true);
    let failed = 0;
    for (const item of selectedItems) {
      const outcome = await saveToPhotos(creationUri(item.fileName), item.type);
      if (!outcome.ok) failed++;
    }
    setWorking(false);
    if (failed === 0) {
      toast.show({ message: `Saved ${selectedItems.length} to Photos`, icon: 'check' });
      cancelSelect();
    } else {
      toast.show({ message: `${failed} couldn't be saved`, tone: 'error' });
    }
  };

  const shareSelected = () =>
    shareMany(selectedItems.map(c => ({ uri: creationUri(c.fileName), type: c.type })));

  const deleteSelected = () => {
    const n = selectedItems.length;
    Alert.alert(
      `Delete ${n} ${n === 1 ? 'item' : 'items'}?`,
      `${n === 1 ? 'It' : 'They'} will be removed from Library. Copies saved to your photos are kept.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: async () => {
            await deleteCreations(selectedItems.map(c => c.id));
            toast.show({ message: `Deleted ${n} ${n === 1 ? 'item' : 'items'}`, icon: 'trash' });
            cancelSelect();
          },
        },
      ],
    );
  };

  const cell = (width - GAP * (COLUMNS - 1)) / COLUMNS;
  const hasAny = creations.length > 0;

  return (
    <View style={styles.screen}>
      {/* Header */}
      <View
        style={[
          styles.header,
          // Same height in both modes so the chips and grid don't jump.
          { paddingTop: insets.top + Spacing.md, height: insets.top + Spacing.md + 44 + Spacing.md },
        ]}>
        {selecting ? (
          <>
            <Pressable hitSlop={10} onPress={cancelSelect} accessibilityRole="button">
              <Text style={styles.headerAction}>Cancel</Text>
            </Pressable>
            <Text style={Type.heading}>
              {selected.size === 0 ? 'Select items' : `${selected.size} selected`}
            </Text>
            <View style={styles.headerSpacer} />
          </>
        ) : (
          <>
            <Text style={styles.title}>Library</Text>
            {hasAny && (
              <Pressable
                hitSlop={10}
                onPress={() => setSelecting(true)}
                accessibilityRole="button"
                style={({ pressed }) => [styles.selectButton, pressed && styles.pressed]}>
                <Text style={styles.selectText}>Select</Text>
              </Pressable>
            )}
          </>
        )}
      </View>

      {hasAny && (
        <View style={styles.chips}>
          {(
            [
              ['all', 'All'],
              ['image', 'Photos'],
              ['video', 'Videos'],
            ] as Array<[Filter, string]>
          ).map(([key, label]) => {
            const on = filter === key;
            return (
              <Pressable
                key={key}
                accessibilityRole="button"
                accessibilityState={{ selected: on }}
                onPress={() => setFilter(key)}
                style={[styles.chip, on && styles.chipOn]}>
                <Text style={[styles.chipText, on && styles.chipTextOn]}>
                  {label} · {counts[key]}
                </Text>
              </Pressable>
            );
          })}
        </View>
      )}

      {!loaded ? (
        <ActivityIndicator style={styles.loading} color={Colors.textSecondary} />
      ) : !hasAny ? (
        <View style={styles.empty}>
          <View style={styles.emptyIcon}>
            <Icon name="grid" size={28} color={Colors.textSecondary} />
          </View>
          <Text style={styles.emptyTitle}>Your edits live here</Text>
          <Text style={[Type.body, styles.emptyText]}>
            Every photo and video you edit is kept in Library, so you can save, share or change it later.
          </Text>
          <Pressable
            accessibilityRole="button"
            onPress={onCreate}
            style={({ pressed }) => [styles.emptyButton, pressed && styles.pressed]}>
            <Icon name="plus" size={18} color={Colors.onAccent} />
            <Text style={styles.emptyButtonText}>Start editing</Text>
          </Pressable>
        </View>
      ) : sections.length === 0 ? (
        <Text style={[Type.body, styles.noMatch]}>
          No {filter === 'video' ? 'videos' : 'photos'} yet.
        </Text>
      ) : (
        <SectionList
          sections={sections}
          keyExtractor={row => row.map(c => c.id).join('|')}
          stickySectionHeadersEnabled={false}
          contentContainerStyle={{ paddingBottom: bottomSpace + Spacing.xl }}
          renderSectionHeader={({ section }) => (
            <Text style={styles.sectionTitle}>{section.title}</Text>
          )}
          renderItem={({ item: row }) => (
            <View style={styles.row}>
              {row.map(item => (
                <MediaTile
                  key={item.id}
                  item={item}
                  width={cell}
                  height={cell}
                  selecting={selecting}
                  selected={selected.has(item.id)}
                  onPress={onTilePress}
                  onLongPress={selecting ? undefined : onTileLongPress}
                />
              ))}
            </View>
          )}
        />
      )}

      {selecting && (
        <View style={[styles.actionBar, { paddingBottom: Math.max(insets.bottom, Spacing.md) }]}>
          <BarAction icon="download" label="Save" disabled={selected.size === 0 || working} onPress={saveSelected} />
          <BarAction icon="share" label="Share" disabled={selected.size === 0} onPress={shareSelected} />
          <BarAction icon="trash" label="Delete" danger disabled={selected.size === 0} onPress={deleteSelected} />
        </View>
      )}

      {working && (
        <View style={styles.working}>
          <ActivityIndicator color={Colors.text} />
        </View>
      )}
    </View>
  );
};

const BarAction: React.FC<{
  icon: IconName;
  label: string;
  danger?: boolean;
  disabled?: boolean;
  onPress: () => void;
}> = ({ icon, label, danger, disabled, onPress }) => (
  <Pressable
    accessibilityRole="button"
    accessibilityLabel={label}
    disabled={disabled}
    onPress={onPress}
    style={({ pressed }) => [styles.barAction, pressed && styles.pressed, disabled && styles.disabled]}>
    <Icon name={icon} size={22} color={danger ? Colors.danger : Colors.text} />
    <Text style={[styles.barLabel, danger && styles.danger]}>{label}</Text>
  </Pressable>
);

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: Colors.bg },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.page,
    paddingBottom: Spacing.md,
  },
  title: { fontFamily: Fonts.bold, fontSize: 28, color: Colors.text, letterSpacing: -0.5 },
  headerAction: { fontFamily: Fonts.medium, fontSize: 15, color: Colors.text },
  headerSpacer: { width: 52 },
  selectButton: {
    paddingHorizontal: 18,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.surface,
    justifyContent: 'center',
  },
  selectText: { fontFamily: Fonts.medium, fontSize: 14, color: Colors.text },
  pressed: { opacity: 0.75 },
  chips: { flexDirection: 'row', gap: Spacing.sm, paddingHorizontal: Spacing.page, marginBottom: Spacing.sm },
  chip: {
    height: 36,
    paddingHorizontal: 14,
    borderRadius: Radius.pill,
    backgroundColor: Colors.surface,
    justifyContent: 'center',
  },
  chipOn: { backgroundColor: Colors.accent },
  chipText: { fontFamily: Fonts.medium, fontSize: 13, color: Colors.textSecondary },
  chipTextOn: { color: Colors.onAccent },
  loading: { marginTop: 60 },
  sectionTitle: {
    fontFamily: Fonts.semiBold,
    fontSize: 14,
    color: Colors.textSecondary,
    paddingHorizontal: Spacing.page,
    paddingTop: Spacing.lg,
    paddingBottom: Spacing.sm,
  },
  row: { flexDirection: 'row', gap: GAP, marginBottom: GAP },
  noMatch: { textAlign: 'center', marginTop: 60 },
  empty: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 40, paddingBottom: 80 },
  emptyIcon: {
    width: 72,
    height: 72,
    borderRadius: 36,
    backgroundColor: Colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: Spacing.lg,
  },
  emptyTitle: { fontFamily: Fonts.semiBold, fontSize: 18, color: Colors.text },
  emptyText: { textAlign: 'center', marginTop: Spacing.sm, lineHeight: 20 },
  emptyButton: {
    marginTop: Spacing.xl,
    height: 48,
    paddingHorizontal: Spacing.xl,
    borderRadius: 14,
    backgroundColor: Colors.accent,
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.sm,
  },
  emptyButtonText: { fontFamily: Fonts.semiBold, fontSize: 15, color: Colors.onAccent },
  actionBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    backgroundColor: Colors.surface,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: Colors.border,
    paddingTop: Spacing.md,
  },
  barAction: { flex: 1, alignItems: 'center', gap: 4 },
  barLabel: { fontFamily: Fonts.medium, fontSize: 12, color: Colors.text },
  danger: { color: Colors.danger },
  disabled: { opacity: 0.35 },
  working: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: Colors.overlay,
    alignItems: 'center',
    justifyContent: 'center',
  },
});

export default LibraryTab;
