import { Platform, PermissionsAndroid } from 'react-native';
import {
  launchCamera,
  launchImageLibrary,
  type Asset,
  type ImagePickerResponse,
} from 'react-native-image-picker';
import RNFS from 'react-native-fs';
import type { MediaType } from '../native/MediaEditor/types';

export type PickedMedia = { uri: string; type: MediaType };

export type PickOutcome =
  | { status: 'picked'; media: PickedMedia }
  | { status: 'cancelled' }
  | { status: 'error'; message: string };

/** The editor reads local files; content:// (some Android pickers) is copied
 *  into the cache first. */
const toLocalFile = async (asset: Asset, type: MediaType): Promise<string> => {
  const uri = asset.uri ?? '';
  if (uri.startsWith('file://') || uri.startsWith('/')) {
    return uri.startsWith('/') ? `file://${uri}` : uri;
  }
  const ext = type === 'video' ? 'mp4' : 'jpg';
  const dest = `${RNFS.CachesDirectoryPath}/pick_${Date.now()}.${ext}`;
  await RNFS.copyFile(uri, dest);
  return `file://${dest}`;
};

const handle = async (
  response: ImagePickerResponse,
  type: MediaType,
): Promise<PickOutcome> => {
  if (response.didCancel) return { status: 'cancelled' };
  if (response.errorCode) {
    if (response.errorCode === 'camera_unavailable') {
      return { status: 'error', message: 'The camera is not available on this device.' };
    }
    if (response.errorCode === 'permission') {
      return {
        status: 'error',
        message: 'Editor needs permission for this. You can allow it in Settings.',
      };
    }
    return { status: 'error', message: response.errorMessage ?? 'Something went wrong.' };
  }
  const asset = response.assets?.[0];
  if (!asset?.uri) return { status: 'cancelled' };
  try {
    const uri = await toLocalFile(asset, type);
    return { status: 'picked', media: { uri, type } };
  } catch {
    return { status: 'error', message: 'Could not open this file.' };
  }
};

/** System photo picker: no library permission needed on iOS 14+ / Android 13+. */
export const pickFromLibrary = async (type: MediaType): Promise<PickOutcome> => {
  const response = await launchImageLibrary({
    mediaType: type === 'video' ? 'video' : 'photo',
    selectionLimit: 1,
    quality: 1,
    // iOS: hand over an H.264-compatible copy (HEVC/HDR clips edit reliably).
    assetRepresentationMode: type === 'video' ? 'compatible' : 'current',
    formatAsMp4: true,
    includeExtra: false,
  });
  return handle(response, type);
};

export const captureWithCamera = async (type: MediaType): Promise<PickOutcome> => {
  if (Platform.OS === 'android') {
    const perms = [PermissionsAndroid.PERMISSIONS.CAMERA];
    if (type === 'video') perms.push(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
    const result = await PermissionsAndroid.requestMultiple(perms);
    if (result[PermissionsAndroid.PERMISSIONS.CAMERA] !== 'granted') {
      return {
        status: 'error',
        message: 'Editor needs camera access. You can allow it in Settings.',
      };
    }
  }
  const response = await launchCamera({
    mediaType: type === 'video' ? 'video' : 'photo',
    quality: 1,
    videoQuality: 'high',
    durationLimit: 600,
    saveToPhotos: false,
    formatAsMp4: true,
  });
  return handle(response, type);
};
