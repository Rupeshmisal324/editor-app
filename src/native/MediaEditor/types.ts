export type MediaType = 'image' | 'video';

/** One entry from the app's music catalog (see staticMusicData.ts), passed
 * once at open time so the native video editor can render its own music
 * picker — never streamed or re-fetched over the bridge after that. */
export interface MusicTrackInput {
  id: string;
  title: string;
  artist: string;
  albumArt: string;
  audioUrl: string;
}

export interface OpenMediaEditorInput {
  uri: string;
  type: MediaType;
  /** Omit to open without a "Music" picker. For `type: 'image'` this is
   * only honored when `isStoryMode` is also true — picking a track there
   * mixes the still photo + trimmed audio into an exported VIDEO, so the
   * result's `type`/`duration` may come back as `'video'` even though the
   * input was an image; the regular (non-story) image editor stays
   * music-free, matching its existing behavior. */
  musicTracks?: MusicTrackInput[];
  /** When true, the editor's primary button reads "Share your story"
   * instead of "Done" — used by the Story camera flow, which shares
   * immediately on tap instead of handing off to a separate preview
   * screen. Also unlocks the Music option for photos (see `musicTracks`).
   * Otherwise purely a label swap; export/result behavior is unchanged. */
  isStoryMode?: boolean;
  /** Google Places key for the story Location tool (Android only; iOS uses
   * MapKit). Filled in automatically by `openMediaEditor` in story mode. */
  placesApiKey?: string;
  /** Opaque native re-edit project from a previous photo export. Filled in
   * automatically by `openMediaEditor` when `uri` is a photo it exported. */
  editProject?: string;
}

/** One cell of a Layout-mode collage. x/y/w/h are normalized (0-1) to the
 * canvas; each photo is center-cropped to its cell's shape. `mirror` flips
 * a front-camera photo to match the preview. */
export interface CollageCell {
  uri: string;
  x: number;
  y: number;
  w: number;
  h: number;
  mirror?: boolean;
  /** Portrait width/height of the camera preview stream the shot was framed
   * in; the photo is cropped to it before the cell crop. */
  previewAspect?: number;
}

export interface ComposeCollageInput {
  cells: CollageCell[];
  width: number;
  height: number;
}

export interface ApplyColorMatrixInput {
  uri: string;
  type: MediaType;
  /** 20-value row-major color matrix, translation normalized 0-1 — the
   * same matrix the story camera's Skia preview draws with. */
  matrix: number[];
}

export interface ApplyShaderEffectInput {
  /** A recorded video (photos are baked in JS with Skia instead). */
  uri: string;
  /** The effect translated for this platform (utils/storyEffectShaders):
   *  a Core Image kernel on iOS, a GLSL ES fragment shader on Android. */
  shader: string;
  /** Android only: the matching vertex shader. */
  vertexShader?: string;
}

export interface CameraPreviewFilterInput {
  /** 4x5 Skia color matrix (translation in 0-1). */
  matrix?: number[];
  /** SkSL effect (`uniform shader image; uniform float2 res;`), run as an
   *  AGSL RuntimeShader. Takes precedence over `matrix`. */
  shader?: string;
}

export interface MakeBoomerangInput {
  /** Short (~1s) recorded clip to sample frames from. */
  videoUri: string;
  /** Frames sampled evenly across the clip. */
  frameCount: number;
  fps: number;
  /** How many forward-then-backward cycles the output plays. */
  loops: number;
}

export type MediaEditorErrorCode =
  | 'invalid_media'
  | 'export_failed'
  | 'processing_error';

/**
 * Always resolves — cancel/error are variants of this union, not rejections.
 * The Promise only rejects for truly exceptional native-side failures (e.g.
 * the module itself is missing).
 */
/** A tappable sticker baked into the exported media (story Location for
 * now). x/y = center, w/h = unrotated size, all as fractions of the
 * exported media's width/height; `aspect` = media width / height. Sent
 * with the story upload as the `stickers` field and returned by the
 * backend on each story, so viewers can tap it (see IgStories). */
export interface StorySticker {
  /** location → opens Maps; link → opens `url` (a program share link opens
   * the program in-app); hashtag → searches `tag`. */
  type: 'location' | 'link' | 'hashtag';
  name: string;
  lat: number | null;
  lng: number | null;
  url?: string;
  tag?: string;
  x: number;
  y: number;
  w: number;
  h: number;
  rotation: number;
  aspect: number;
}

export type MediaEditorResult =
  | {
      status: 'success';
      type: MediaType;
      uri: string;
      width: number;
      height: number;
      duration: number;
      /** Location stickers on the export; empty/absent when there are none. */
      stickers?: StorySticker[];
      /** Opaque native re-edit project (photo exports only). Tracked by
       * `openMediaEditor`; callers don't need to read it. */
      editProject?: string;
    }
  | { status: 'cancelled' }
  | { status: 'error'; code: MediaEditorErrorCode; message: string };

/**
 * Full editor state shape. This mirrors what the Swift/Kotlin sides model
 * natively — it never crosses the RN bridge (see architecture doc: only
 * OpenMediaEditorInput and MediaEditorResult do). Milestone 1's native code
 * only implements MediaState; the rest lands with their owning modules
 * (crop, filters, text/stickers, music, video trim).
 */
export interface MediaState {
  mediaType: MediaType;
  sourceUri: string;
  width: number;
  height: number;
  duration: number;
}

export interface TransformState {
  x: number;
  y: number;
  scale: number;
  rotation: number;
}

export interface CropState {
  cropRect: { x: number; y: number; width: number; height: number };
  aspectRatio: number | null;
}

export type FilterId = 'original' | 'vivid' | 'warm' | 'vintage' | 'blackAndWhite';

export interface FilterState {
  filterId: FilterId;
  intensity: number;
}

export interface AdjustmentState {
  brightness: number;
  contrast: number;
  saturation: number;
}

interface BaseLayer {
  id: string;
  position: { x: number; y: number };
  scale: number;
  rotation: number;
  opacity: number;
}

export interface TextLayer extends BaseLayer {
  type: 'text';
  text: string;
  font: string;
  fontSize: number;
  color: string;
}

export interface StickerLayer extends BaseLayer {
  type: 'sticker';
  asset: string;
}

export type Layer = TextLayer | StickerLayer;

export interface AudioState {
  musicUri: string | null;
  musicStart: number;
  musicEnd: number;
  musicVolume: number;
  originalAudioVolume: number;
  originalAudioMuted: boolean;
}

export interface VideoState {
  trimStart: number;
  trimEnd: number;
  currentTime: number;
}

export interface EditorState {
  media: MediaState;
  transform: TransformState;
  crop: CropState;
  filter: FilterState;
  adjustment: AdjustmentState;
  layers: Layer[];
  audio: AudioState;
  video: VideoState | null;
}
