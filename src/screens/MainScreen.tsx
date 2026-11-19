import React, { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, BackHandler, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import Icon, { type IconName } from '../components/Icon';
import CreateSheet from '../components/CreateSheet';
import HomeTab from './HomeTab';
import LibraryTab, { type LibrarySelection } from './LibraryTab';
import { Colors, Fonts, Spacing, Type } from '../theme';
import { useEditFlow, type EditSource } from '../media/useEditFlow';
import type { MediaType } from '../native/MediaEditor/types';
import type { RootStackParamList } from '../navigation';

type Props = NativeStackScreenProps<RootStackParamList, 'Main'>;
type Tab = 'home' | 'library';

export const TAB_BAR_HEIGHT = 64;

/** Home + Library behind one bottom bar, with Create in the middle. */
const MainScreen: React.FC<Props> = ({ navigation }) => {
  const insets = useSafeAreaInsets();
  const [tab, setTab] = useState<Tab>('home');
  const [sheetOpen, setSheetOpen] = useState(false);
  const [selection, setSelection] = useState<LibrarySelection | null>(null);
  const { busy, startNew } = useEditFlow();

  const start = useCallback(
    async (type: MediaType, source: EditSource) => {
      setSheetOpen(false);
      const creation = await startNew(type, source);
      if (creation) navigation.navigate('Result', { id: creation.id, fresh: true });
    },
    [navigation, startNew],
  );

  // Android back: leave select mode / Library before leaving the app.
  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      if (!navigation.isFocused()) return false;
      if (selection) {
        selection.cancel();
        return true;
      }
      if (tab === 'library') {
        setTab('home');
        return true;
      }
      return false;
    });
    return () => sub.remove();
  }, [navigation, selection, tab]);

  const bottomInset = Math.max(insets.bottom, Spacing.sm);

  return (
    <View style={styles.screen}>
      <View style={[styles.page, tab !== 'home' && styles.hidden]}>
        <HomeTab
          bottomSpace={TAB_BAR_HEIGHT + bottomInset}
          onStart={start}
          onOpen={id => navigation.navigate('Result', { id })}
          onSeeAll={() => setTab('library')}
          onSettings={() => navigation.navigate('Settings')}
        />
      </View>
      <View style={[styles.page, tab !== 'library' && styles.hidden]}>
        <LibraryTab
          active={tab === 'library'}
          bottomSpace={TAB_BAR_HEIGHT + bottomInset}
          onOpen={id => navigation.navigate('Result', { id })}
          onCreate={() => setSheetOpen(true)}
          onSelectionChange={setSelection}
        />
      </View>

      {!selection && (
        <View style={[styles.tabBar, { paddingBottom: bottomInset, height: TAB_BAR_HEIGHT + bottomInset }]}>
          <TabButton icon="home" label="Home" active={tab === 'home'} onPress={() => setTab('home')} />
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Create"
            onPress={() => setSheetOpen(true)}
            style={({ pressed }) => [styles.createButton, pressed && styles.createPressed]}>
            <Icon name="plus" size={26} color={Colors.onAccent} />
          </Pressable>
          <TabButton icon="grid" label="Library" active={tab === 'library'} onPress={() => setTab('library')} />
        </View>
      )}

      <CreateSheet visible={sheetOpen} onClose={() => setSheetOpen(false)} onPick={start} />

      {busy && (
        <View style={styles.busy}>
          <ActivityIndicator color={Colors.text} />
          <Text style={[Type.label, styles.busyText]}>Saving your edit…</Text>
        </View>
      )}
    </View>
  );
};

const TabButton: React.FC<{
  icon: IconName;
  label: string;
  active: boolean;
  onPress: () => void;
}> = ({ icon, label, active, onPress }) => (
  <Pressable
    accessibilityRole="tab"
    accessibilityState={{ selected: active }}
    accessibilityLabel={label}
    onPress={onPress}
    style={styles.tabButton}>
    <Icon name={icon} size={23} color={active ? Colors.text : Colors.textMuted} />
    <Text style={[styles.tabLabel, active && styles.tabLabelActive]}>{label}</Text>
  </Pressable>
);

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: Colors.bg },
  page: { ...StyleSheet.absoluteFillObject },
  hidden: { display: 'none' },
  tabBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-around',
    backgroundColor: 'rgba(11,11,13,0.96)',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: Colors.border,
    paddingTop: 6,
  },
  tabButton: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 3, height: TAB_BAR_HEIGHT - 6 },
  tabLabel: { fontFamily: Fonts.medium, fontSize: 12, color: Colors.textMuted },
  tabLabelActive: { color: Colors.text },
  createButton: {
    width: 56,
    height: 44,
    borderRadius: 16,
    backgroundColor: Colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  createPressed: { opacity: 0.8, transform: [{ scale: 0.96 }] },
  busy: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: Colors.overlay,
    alignItems: 'center',
    justifyContent: 'center',
  },
  busyText: { marginTop: Spacing.md },
});

export default MainScreen;
