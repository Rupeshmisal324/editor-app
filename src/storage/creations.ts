import AsyncStorage from '@react-native-async-storage/async-storage';
import RNFS from 'react-native-fs';
import { createThumbnail } from 'react-native-create-thumbnail';
import type { MediaType } from '../native/MediaEditor/types';

/**
 * The user's finished edits ("My work"). Editor exports land in the cache
 * (which the OS and the editor itself clean up), so each one is copied into
 * Documents/Creations. Only file NAMES are stored: the app's container path
 * changes between iOS updates, so full paths would break.
 */
export type Creation = {
  id: string;
  type: MediaType;
  fileName: string;
  thumbFileName?: string;
  width: number;
  height: number;
  /** Seconds (video only). */
  duration: number;
  createdAt: number;
  /** Native re-edit data (photos only); keeps text/stickers editable. */
  editProject?: string;
};

const KEY = 'editor.creations.v1';
const DIR = `${RNFS.DocumentDirectoryPath}/Creations`;

export const creationUri = (name: string) => `file://${DIR}/${name}`;

const stripScheme = (uri: string) => {
  const path = uri.replace(/^file:\/\//, '');
  try {
    return decodeURI(path);
  } catch {
    return path;
  }
};

const extensionOf = (uri: string, type: MediaType) => {
  const match = /\.([A-Za-z0-9]+)(?:\?|$)/.exec(uri);
  return (match?.[1] ?? (type === 'video' ? 'mp4' : 'jpg')).toLowerCase();
};

let cache: Creation[] | null = null;
const listeners = new Set<(list: Creation[]) => void>();

const emit = (list: Creation[]) => {
  cache = list;
  listeners.forEach(l => l(list));
};

const persist = async (list: Creation[]) => {
  emit(list);
  await AsyncStorage.setItem(KEY, JSON.stringify(list));
};

export const loadCreations = async (): Promise<Creation[]> => {
  if (cache) return cache;
  try {
    const raw = await AsyncStorage.getItem(KEY);
    const parsed: Creation[] = raw ? JSON.parse(raw) : [];
    // Drop entries whose file is gone (e.g. deleted by the user elsewhere).
    const checks = await Promise.all(
      parsed.map(c => RNFS.exists(`${DIR}/${c.fileName}`).catch(() => false)),
    );
    const alive = parsed.filter((_, i) => checks[i]);
    if (alive.length !== parsed.length) await persist(alive);
    else emit(alive);
    return alive;
  } catch {
    emit([]);
    return [];
  }
};

export const subscribeCreations = (listener: (list: Creation[]) => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

export const getCreation = (id: string) => cache?.find(c => c.id === id);

type ExportResult = {
  type: MediaType;
  uri: string;
  width: number;
  height: number;
  duration: number;
  editProject?: string;
};

/** Copies an editor export into Documents and adds it to the top of the list. */
export const addCreation = async (
  result: ExportResult,
  replaceId?: string,
): Promise<Creation> => {
  await RNFS.mkdir(DIR);
  const id = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  const fileName = `${id}.${extensionOf(result.uri, result.type)}`;
  await RNFS.copyFile(stripScheme(result.uri), `${DIR}/${fileName}`);

  let thumbFileName: string | undefined;
  if (result.type === 'video') {
    try {
      const thumb = await createThumbnail({
        url: creationUri(fileName),
        timeStamp: 0,
        format: 'jpeg',
      });
      thumbFileName = `${id}_thumb.jpg`;
      await RNFS.moveFile(stripScheme(thumb.path), `${DIR}/${thumbFileName}`);
    } catch {
      thumbFileName = undefined;
    }
  }

  const creation: Creation = {
    id,
    type: result.type,
    fileName,
    thumbFileName,
    width: result.width,
    height: result.height,
    duration: result.duration,
    createdAt: Date.now(),
    editProject: result.editProject,
  };
  const list = (await loadCreations()).filter(c => c.id !== replaceId);
  if (replaceId) {
    const old = cache?.find(c => c.id === replaceId);
    if (old) await deleteFiles(old);
  }
  await persist([creation, ...list]);
  return creation;
};

const deleteFiles = async (c: Creation) => {
  await RNFS.unlink(`${DIR}/${c.fileName}`).catch(() => {});
  if (c.thumbFileName) {
    await RNFS.unlink(`${DIR}/${c.thumbFileName}`).catch(() => {});
  }
};

export const deleteCreation = async (id: string) => {
  const list = await loadCreations();
  const target = list.find(c => c.id === id);
  if (target) await deleteFiles(target);
  await persist(list.filter(c => c.id !== id));
};

export const deleteAllCreations = async () => {
  await RNFS.unlink(DIR).catch(() => {});
  await persist([]);
};

export const creationsSizeBytes = async (): Promise<number> => {
  try {
    const items = await RNFS.readDir(DIR);
    return items.reduce((sum, f) => sum + Number(f.size || 0), 0);
  } catch {
    return 0;
  }
};

export const deleteCreations = async (ids: string[]) => {
  const remove = new Set(ids);
  const list = await loadCreations();
  await Promise.all(list.filter(c => remove.has(c.id)).map(deleteFiles));
  await persist(list.filter(c => !remove.has(c.id)));
};

/** Today / Yesterday / This week / Month Year — for Library section titles. */
export const dateGroupTitle = (timestamp: number, now = Date.now()): string => {
  const startOfDay = (t: number) => {
    const d = new Date(t);
    d.setHours(0, 0, 0, 0);
    return d.getTime();
  };
  const days = Math.round((startOfDay(now) - startOfDay(timestamp)) / 86400000);
  if (days <= 0) return 'Today';
  if (days === 1) return 'Yesterday';
  if (days < 7) return 'This week';
  return new Date(timestamp).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
};
