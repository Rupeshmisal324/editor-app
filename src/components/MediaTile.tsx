import React, { memo } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import Icon from './Icon';
import { Colors, Fonts } from '../theme';
import { creationUri, type Creation } from '../storage/creations';

export const formatDuration = (seconds: number) => {
  const total = Math.max(0, Math.round(seconds));
  return `${Math.floor(total / 60)}:${(total % 60).toString().padStart(2, '0')}`;
};

type Props = {
  item: Creation;
  width: number;
  height: number;
  radius?: number;
  selecting?: boolean;
  selected?: boolean;
  onPress: (item: Creation) => void;
  onLongPress?: (item: Creation) => void;
};

/** One edited photo/video: thumbnail, video length, selection tick. */
const MediaTile: React.FC<Props> = ({
  item,
  width,
  height,
  radius = 0,
  selecting,
  selected,
  onPress,
  onLongPress,
}) => (
  <Pressable
    accessibilityRole="imagebutton"
    accessibilityLabel={`${item.type === 'video' ? 'Video' : 'Photo'}${selected ? ', selected' : ''}`}
    onPress={() => onPress(item)}
    onLongPress={onLongPress ? () => onLongPress(item) : undefined}
    delayLongPress={250}
    style={({ pressed }) => [
      { width, height, borderRadius: radius },
      styles.tile,
      pressed && styles.pressed,
    ]}>
    <Image
      source={{
        uri: creationUri(
          item.type === 'video' ? item.thumbFileName ?? item.fileName : item.fileName,
        ),
      }}
      style={[styles.image, selected && styles.imageSelected]}
      resizeMode="cover"
    />
    {item.type === 'video' && (
      <View style={styles.badge}>
        <Icon name="play" size={9} color={Colors.text} />
        <Text style={styles.badgeText}>{formatDuration(item.duration)}</Text>
      </View>
    )}
    {selecting && (
      <View style={[styles.tick, selected && styles.tickOn]}>
        {selected && <Icon name="check" size={13} color={Colors.onAccent} />}
      </View>
    )}
  </Pressable>
);

const styles = StyleSheet.create({
  tile: { overflow: 'hidden', backgroundColor: Colors.surface },
  pressed: { opacity: 0.8 },
  image: { width: '100%', height: '100%' },
  imageSelected: { opacity: 0.55 },
  badge: {
    position: 'absolute',
    left: 6,
    bottom: 6,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    backgroundColor: Colors.overlay,
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
  },
  badgeText: { fontFamily: Fonts.medium, fontSize: 11, color: Colors.text },
  tick: {
    position: 'absolute',
    top: 6,
    right: 6,
    width: 22,
    height: 22,
    borderRadius: 11,
    borderWidth: 1.5,
    borderColor: Colors.text,
    backgroundColor: 'rgba(0,0,0,0.25)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  tickOn: { backgroundColor: Colors.accent, borderColor: Colors.accent },
});

export default memo(MediaTile);
