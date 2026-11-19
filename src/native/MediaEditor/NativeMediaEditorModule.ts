import { NativeModules } from 'react-native';
import type {
  OpenMediaEditorInput,
  MediaEditorResult,
  ComposeCollageInput,
  MakeBoomerangInput,
  ApplyColorMatrixInput,
  ApplyShaderEffectInput,
  CameraPreviewFilterInput,
} from './types';

interface MediaEditorNativeModule {
  open(input: OpenMediaEditorInput): Promise<MediaEditorResult>;
  composeCollage(
    input: ComposeCollageInput,
  ): Promise<{ uri: string; width: number; height: number }>;
  applyColorMatrix(input: ApplyColorMatrixInput): Promise<{ uri: string }>;
  applyShaderEffect(input: ApplyShaderEffectInput): Promise<{ uri: string }>;
  /** Android only: filters a mounted camera preview view in place.
   *  Both fields empty clears the filter. */
  setCameraPreviewFilter?(
    viewTag: number,
    input: CameraPreviewFilterInput,
  ): Promise<void>;
  makeBoomerang(input: MakeBoomerangInput): Promise<{
    uri: string;
    duration: number;
    width: number;
    height: number;
  }>;
}

export default NativeModules.MediaEditorModule as MediaEditorNativeModule;
