import { useCallback, useRef, useState } from 'react';
import { Alert } from 'react-native';
import { openMediaEditor } from '../native/MediaEditor/openMediaEditor';
import type { MediaType } from '../native/MediaEditor/types';
import { captureWithCamera, pickFromLibrary } from './pickMedia';
import { addCreation, creationUri, type Creation } from '../storage/creations';

export type EditSource = 'library' | 'camera';

/**
 * pick (or capture) → native editor → keep the export in "My work".
 * Resolves the new creation, or null when the user backed out anywhere.
 */
export const useEditFlow = () => {
  const [busy, setBusy] = useState(false);
  const running = useRef(false);

  const runEditor = useCallback(
    async (
      uri: string,
      type: MediaType,
      options?: { editProject?: string; replaceId?: string },
    ): Promise<Creation | null> => {
      const result = await openMediaEditor({
        uri,
        type,
        editProject: options?.editProject,
      });
      if (result.status === 'cancelled') return null;
      if (result.status === 'error') {
        Alert.alert('Could not edit', result.message || 'Please try another file.');
        return null;
      }
      setBusy(true);
      try {
        return await addCreation(result, options?.replaceId);
      } catch {
        Alert.alert('Could not save your edit', 'Please free up some space and try again.');
        return null;
      } finally {
        setBusy(false);
      }
    },
    [],
  );

  const startNew = useCallback(
    async (type: MediaType, source: EditSource): Promise<Creation | null> => {
      if (running.current) return null;
      running.current = true;
      try {
        const picked =
          source === 'camera' ? await captureWithCamera(type) : await pickFromLibrary(type);
        if (picked.status === 'cancelled') return null;
        if (picked.status === 'error') {
          Alert.alert('Editor', picked.message);
          return null;
        }
        return await runEditor(picked.media.uri, type);
      } finally {
        running.current = false;
      }
    },
    [runEditor],
  );

  /** Reopens a saved creation; photos come back with their layers editable. */
  const editAgain = useCallback(
    async (creation: Creation): Promise<Creation | null> => {
      if (running.current) return null;
      running.current = true;
      try {
        return await runEditor(creationUri(creation.fileName), creation.type, {
          editProject: creation.editProject,
        });
      } finally {
        running.current = false;
      }
    },
    [runEditor],
  );

  return { busy, startNew, editAgain };
};
