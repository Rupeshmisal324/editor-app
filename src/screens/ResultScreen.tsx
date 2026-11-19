import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import Video from 'react-native-video';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useIsFocused } from '@react-navigation/native';
import type { NativeStackScreenProps } from '@react-navigation/native-stack';
import Icon, { type IconName } from '../components/Icon';
import { Colors, Fonts, Spacing, Type } from '../theme';
import {
  creationUri,
  deleteCreation,
  getCreation,
  loadCreations,
  type Creation,
} from '../storage/creations';
import { saveToPhotos, shareMedia } from '../media/exportMedia';
import { useToast } from '../components/Toast';
import { formatDuration } from '../components/MediaTile';
import { dateGroupTitle } from '../storage/creations';
import { useEditFlow } from '../media/useEditFlow';
import type { RootStackParamList } from '../navigation';

type Props = NativeStackScreenProps<RootStackParamList, 'Result'>;

const ResultScreen: React.FC<Props> = ({ navigation, route }) => {
  const insets = useSafeAreaInsets();
  const focused = useIsFocused();
  const [creation, setCreation] = useState<Creation | undefined>(() =>
    getCreation(route.params.id),
  );
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [paused, setPaused] = useState(false);
  const { busy, editAgain } = useEditFlow();
  const toast = useToast();

  useEffect(() => {
    setSaved(false);
    if (creation?.id === route.params.id) return;
    loadCreations().then(list => setCreation(list.find(c => c.id === route.params.id)));
  }, [creation?.id, route.params.id]);

  const uri = creation ? creationUri(creation.fileName) : '';

  const onSave = useCallback(async () => {
    if (!creation || saving) return;
    setSaving(true);
    const outcome = await saveToPhotos(uri, creation.type);
    setSaving(false);
    if (outcome.ok) {
      setSaved(true);
      toast.show({ message: 'Saved to Photos', icon: 'check' });
    } else {
      toast.show({ message: outcome.message, tone: 'error' });
    }
  }, [creation, saving, toast, uri]);

  const onShare = useCallback(() => {
    if (creation) shareMedia(uri, creation.type);
  }, [creation, uri]);

  const onEdit = useCallback(async () => {
    if (!creation) return;
    setPaused(true);
    const next = await editAgain(creation);
    if (next) navigation.replace('Result', { id: next.id, fresh: true });
  }, [creation, editAgain, navigation]);

  const onDelete = useCallback(() => {
    if (!creation) return;
    Alert.alert(
      creation.type === 'video' ? 'Delete this video?' : 'Delete this photo?',
      'It will be removed from Library. Copies saved to your photos are kept.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: async () => {
            await deleteCreation(creation.id);
            toast.show({ message: 'Deleted', icon: 'trash' });
            navigation.goBack();
          },
        },
      ],
    );
  }, [creation, navigation, toast]);

  const details = creation
    ? [
        creation.type === 'video' ? `Video · ${formatDuration(creation.duration)}` : 'Photo',
        creation.width && creation.height ? `${creation.width} × ${creation.height}` : null,
        dateGroupTitle(creation.createdAt),
      ]
        .filter(Boolean)
        .join('  ·  ')
    : '';

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
        <Text style={Type.heading}>
          {route.params.fresh ? 'Your edit is ready' : creation?.type === 'video' ? 'Video' : 'Photo'}
        </Text>
        <Pressable
          accessibilityLabel="Delete"
          hitSlop={10}
          onPress={onDelete}
          style={styles.roundButton}>
          <Icon name="trash" size={20} color={Colors.danger} />
        </Pressable>
      </View>

      <View style={styles.media}>
        {!creation ? (
          <ActivityIndicator color={Colors.text} />
        ) : creation.type === 'video' ? (
          <View style={styles.fill}>
            <Video
              source={{ uri }}
              style={styles.fill}
              resizeMode="contain"
              repeat
              paused={paused || !focused || busy}
              playInBackground={false}
              ignoreSilentSwitch="obey"
            />
            {/* Tap layer above the player: on Android the video surface
                swallows touches, so a wrapping Pressable never fired. */}
            <Pressable
              accessibilityRole="button"
              accessibilityLabel={paused ? 'Play' : 'Pause'}
              style={StyleSheet.absoluteFill}
              onPress={() => setPaused(p => !p)}
            />
            {paused && (
              <View style={styles.playOverlay} pointerEvents="none">
                <View style={styles.playButton}>
                  <Icon name="play" size={26} color={Colors.text} />
                </View>
              </View>
            )}
          </View>
        ) : (
          <Image source={{ uri }} style={styles.fill} resizeMode="contain" />
        )}
      </View>

      {!!details && <Text style={[Type.caption, styles.details]}>{details}</Text>}

      <View style={[styles.actions, { paddingBottom: insets.bottom + Spacing.md }]}>
        <Action
          icon={saved ? 'check' : 'download'}
          label={saved ? 'Saved' : 'Save'}
          loading={saving}
          onPress={onSave}
          primary
        />
        <Action icon="share" label="Share" onPress={onShare} />
        <Action icon="edit" label="Edit" onPress={onEdit} />
      </View>

      {busy && (
        <View style={styles.busy}>
          <ActivityIndicator color={Colors.text} />
          <Text style={[Type.label, styles.busyText]}>Saving your edit…</Text>
        </View>
      )}
    </View>
  );
};

const Action: React.FC<{
  icon: IconName;
  label: string;
  onPress: () => void;
  primary?: boolean;
  loading?: boolean;
}> = ({ icon, label, onPress, primary, loading }) => (
  <Pressable
    accessibilityRole="button"
    accessibilityLabel={label}
    onPress={onPress}
    disabled={loading}
    style={({ pressed }) => [
      styles.action,
      primary && styles.actionPrimary,
      pressed && styles.actionPressed,
    ]}>
    {loading ? (
      <ActivityIndicator color={primary ? Colors.onAccent : Colors.text} />
    ) : (
      <>
        <Icon name={icon} size={20} color={primary ? Colors.onAccent : Colors.text} />
        <Text style={[styles.actionText, primary && styles.actionTextPrimary]}>{label}</Text>
      </>
    )}
  </Pressable>
);

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: Colors.bg },
  topBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.sm,
  },
  roundButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.surface,
    alignItems: 'center',
    justifyContent: 'center',
  },
  media: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#000' },
  fill: { width: '100%', height: '100%' },
  playOverlay: { ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center' },
  playButton: {
    width: 64,
    height: 64,
    borderRadius: 32,
    backgroundColor: Colors.overlay,
    alignItems: 'center',
    justifyContent: 'center',
    paddingLeft: 4,
  },
  details: { textAlign: 'center', paddingTop: Spacing.md },
  actions: {
    flexDirection: 'row',
    gap: Spacing.md,
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.md,
  },
  action: {
    flex: 1,
    height: 52,
    borderRadius: 14,
    backgroundColor: Colors.surface,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: Spacing.sm,
  },
  actionPrimary: { backgroundColor: Colors.accent },
  actionPressed: { opacity: 0.75 },
  actionText: { fontFamily: Fonts.medium, fontSize: 15, color: Colors.text },
  actionTextPrimary: { color: Colors.onAccent },
  busy: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: Colors.overlay,
    alignItems: 'center',
    justifyContent: 'center',
  },
  busyText: { marginTop: Spacing.md },
});

export default ResultScreen;
