import { Platform, PermissionsAndroid } from 'react-native';
import { CameraRoll } from '@react-native-camera-roll/camera-roll';
import Share from 'react-native-share';
import type { MediaType } from '../native/MediaEditor/types';

const ALBUM = 'Editor';

const ensureSavePermission = async (): Promise<boolean> => {
  // Android 10+ saves through MediaStore without a permission.
  if (Platform.OS !== 'android' || Number(Platform.Version) >= 29) return true;
  const result = await PermissionsAndroid.request(
    PermissionsAndroid.PERMISSIONS.WRITE_EXTERNAL_STORAGE,
  );
  return result === PermissionsAndroid.RESULTS.GRANTED;
};

export type SaveOutcome = { ok: true } | { ok: false; message: string };

export const saveToPhotos = async (
  uri: string,
  type: MediaType,
): Promise<SaveOutcome> => {
  if (!(await ensureSavePermission())) {
    return { ok: false, message: 'Allow storage access in Settings to save.' };
  }
  try {
    await CameraRoll.saveAsset(uri, { type: type === 'video' ? 'video' : 'photo', album: ALBUM });
    return { ok: true };
  } catch (e: any) {
    const denied = /denied|not authorized|permission/i.test(String(e?.message ?? e));
    return {
      ok: false,
      message: denied
        ? 'Allow Editor to add to your photos in Settings to save.'
        : 'Could not save. Please try again.',
    };
  }
};

export const shareMedia = async (uri: string, type: MediaType) => {
  try {
    await Share.open({
      url: uri,
      type: type === 'video' ? 'video/mp4' : 'image/jpeg',
      failOnCancel: false,
    });
  } catch {
    // Dismissed or no target app; nothing to do.
  }
};

/** Shares several items in one sheet (Library selection). */
export const shareMany = async (items: Array<{ uri: string; type: MediaType }>) => {
  if (items.length === 0) return;
  if (items.length === 1) return shareMedia(items[0].uri, items[0].type);
  const allVideo = items.every(i => i.type === 'video');
  const allImage = items.every(i => i.type === 'image');
  try {
    await Share.open({
      urls: items.map(i => i.uri),
      type: allVideo ? 'video/*' : allImage ? 'image/*' : '*/*',
      failOnCancel: false,
    });
  } catch {
    // Dismissed.
  }
};
