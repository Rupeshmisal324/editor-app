import NativeMediaEditorModule from './NativeMediaEditorModule';
import type { OpenMediaEditorInput, MediaEditorResult } from './types';

/**
 * Opens the native photo/video editor (the same native code as IntoActiv).
 * Always resolves: 'success' | 'cancelled' | 'error'.
 */
export async function openMediaEditor(
  input: OpenMediaEditorInput,
): Promise<MediaEditorResult> {
  if (!NativeMediaEditorModule?.open) {
    return {
      status: 'error',
      code: 'processing_error',
      message: 'The editor is not available in this build.',
    };
  }
  return NativeMediaEditorModule.open(input);
}

export type { MediaEditorResult, MediaType } from './types';
