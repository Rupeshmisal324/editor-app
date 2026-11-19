import React, { useEffect, useRef } from 'react';
import { Animated, Modal, Pressable, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Icon, { type IconName } from './Icon';
import { Colors, Fonts, Radius, Spacing, Type } from '../theme';
import type { MediaType } from '../native/MediaEditor/types';
import type { EditSource } from '../media/useEditFlow';

type Props = {
  visible: boolean;
  onClose: () => void;
  onPick: (type: MediaType, source: EditSource) => void;
};

const OPTIONS: Array<{
  type: MediaType;
  source: EditSource;
  icon: IconName;
  title: string;
  detail: string;
}> = [
  { type: 'image', source: 'library', icon: 'photo', title: 'Photo', detail: 'From your gallery' },
  { type: 'video', source: 'library', icon: 'video', title: 'Video', detail: 'From your gallery' },
  { type: 'image', source: 'camera', icon: 'camera', title: 'Take photo', detail: 'Use the camera' },
  { type: 'video', source: 'camera', icon: 'video', title: 'Record video', detail: 'Use the camera' },
];

/** "Create" bottom sheet behind the tab bar's + button. */
const CreateSheet: React.FC<Props> = ({ visible, onClose, onPick }) => {
  const insets = useSafeAreaInsets();
  const progress = useRef(new Animated.Value(0)).current;

  useEffect(() => {
    if (visible) {
      progress.setValue(0);
      Animated.spring(progress, {
        toValue: 1,
        useNativeDriver: true,
        damping: 22,
        stiffness: 260,
      }).start();
    }
  }, [progress, visible]);

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose} statusBarTranslucent>
      <Pressable accessibilityLabel="Close" style={styles.backdrop} onPress={onClose} />
      <Animated.View
        style={[
          styles.sheet,
          { paddingBottom: insets.bottom + Spacing.lg },
          {
            transform: [
              { translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [320, 0] }) },
            ],
          },
        ]}>
        <View style={styles.handle} />
        <View style={styles.header}>
          <Text style={Type.heading}>Create</Text>
          <Pressable accessibilityLabel="Close" hitSlop={10} onPress={onClose} style={styles.close}>
            <Icon name="close" size={18} />
          </Pressable>
        </View>
        <View style={styles.grid}>
          {OPTIONS.map(option => (
            <Pressable
              key={`${option.type}-${option.source}`}
              accessibilityRole="button"
              accessibilityLabel={option.title}
              onPress={() => onPick(option.type, option.source)}
              style={({ pressed }) => [styles.option, pressed && styles.optionPressed]}>
              <View
                style={[
                  styles.optionIcon,
                  option.source === 'library' ? styles.optionIconPrimary : null,
                ]}>
                <Icon
                  name={option.icon}
                  size={22}
                  color={option.source === 'library' ? Colors.onAccent : Colors.text}
                />
              </View>
              <Text style={styles.optionTitle}>{option.title}</Text>
              <Text style={Type.caption}>{option.detail}</Text>
            </Pressable>
          ))}
        </View>
      </Animated.View>
    </Modal>
  );
};

const styles = StyleSheet.create({
  backdrop: { ...StyleSheet.absoluteFillObject, backgroundColor: 'rgba(0,0,0,0.6)' },
  sheet: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: Colors.surface,
    borderTopLeftRadius: 24,
    borderTopRightRadius: 24,
    paddingHorizontal: Spacing.page,
  },
  handle: {
    alignSelf: 'center',
    width: 38,
    height: 4,
    borderRadius: 2,
    backgroundColor: Colors.dot,
    marginTop: Spacing.sm,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 14,
    marginBottom: 18,
  },
  close: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.surfaceHigh,
    alignItems: 'center',
    justifyContent: 'center',
  },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: Spacing.md },
  option: {
    width: '47.5%',
    flexGrow: 1,
    backgroundColor: Colors.surfaceHigh,
    borderRadius: Radius.md,
    padding: Spacing.lg,
  },
  optionPressed: { backgroundColor: Colors.surfacePress },
  optionIcon: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: Colors.surfacePress,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: Spacing.md,
  },
  optionIconPrimary: { backgroundColor: Colors.accent },
  optionTitle: { fontFamily: Fonts.semiBold, fontSize: 15, color: Colors.text, marginBottom: 2 },
});

export default CreateSheet;
