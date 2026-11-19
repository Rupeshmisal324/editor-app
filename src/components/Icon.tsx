import React from 'react';
import Svg, { Path, Circle, Rect } from 'react-native-svg';
import { Colors } from '../theme';

export type IconName =
  | 'photo'
  | 'video'
  | 'camera'
  | 'settings'
  | 'back'
  | 'download'
  | 'share'
  | 'edit'
  | 'trash'
  | 'play'
  | 'check'
  | 'chevron'
  | 'home'
  | 'grid'
  | 'plus'
  | 'close'
  | 'sparkle'
  | 'select'
  | 'info'
  | 'wand';

type Props = { name: IconName; size?: number; color?: string };

/** Simple stroke icons (24×24 grid). */
const Icon: React.FC<Props> = ({ name, size = 22, color = Colors.text }) => {
  const p = {
    stroke: color,
    strokeWidth: 1.8,
    fill: 'none',
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  };
  return (
    <Svg width={size} height={size} viewBox="0 0 24 24">
      {name === 'photo' && (
        <>
          <Rect x={3} y={4} width={18} height={16} rx={3} {...p} />
          <Circle cx={8.5} cy={9.5} r={1.8} {...p} />
          <Path d="M21 16l-5.5-5.5L6 20" {...p} />
        </>
      )}
      {name === 'video' && (
        <>
          <Rect x={2.5} y={5.5} width={13.5} height={13} rx={3} {...p} />
          <Path d="M16 10.5l5.5-3v9l-5.5-3" {...p} />
        </>
      )}
      {name === 'camera' && (
        <>
          <Path
            d="M4 8h3l2-2.5h6L17 8h3a1 1 0 011 1v9a1 1 0 01-1 1H4a1 1 0 01-1-1V9a1 1 0 011-1z"
            {...p}
          />
          <Circle cx={12} cy={13} r={3.5} {...p} />
        </>
      )}
      {name === 'settings' && (
        <>
          <Circle cx={12} cy={12} r={3} {...p} />
          <Path
            d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"
            {...p}
          />
        </>
      )}
      {name === 'back' && <Path d="M15 5l-7 7 7 7" {...p} />}
      {name === 'chevron' && <Path d="M9 5l7 7-7 7" {...p} />}
      {name === 'download' && (
        <>
          <Path d="M12 4v11M7 10.5l5 5 5-5" {...p} />
          <Path d="M4 17v2a1 1 0 001 1h14a1 1 0 001-1v-2" {...p} />
        </>
      )}
      {name === 'share' && (
        <>
          <Path d="M12 15V4M7.5 8.5L12 4l4.5 4.5" {...p} />
          <Path d="M5 12v7a1 1 0 001 1h12a1 1 0 001-1v-7" {...p} />
        </>
      )}
      {name === 'edit' && (
        <Path d="M4 20h4L19 9a2.8 2.8 0 00-4-4L4 16v4zM13.5 6.5l4 4" {...p} />
      )}
      {name === 'trash' && (
        <Path
          d="M4 7h16M10 11v6M14 11v6M6 7l1 12a1 1 0 001 1h8a1 1 0 001-1l1-12M9 7V4.5a.5.5 0 01.5-.5h5a.5.5 0 01.5.5V7"
          {...p}
        />
      )}
      {name === 'play' && <Path d="M8 5.5v13l10.5-6.5L8 5.5z" fill={color} />}
      {name === 'check' && <Path d="M5 12.5l4.5 4.5L19 7.5" {...p} />}
      {name === 'home' && (
        <Path d="M4 10.5L12 4l8 6.5V19a1 1 0 01-1 1h-4.5v-5.5h-5V20H5a1 1 0 01-1-1v-8.5z" {...p} />
      )}
      {name === 'grid' && (
        <>
          <Rect x={4} y={4} width={7} height={7} rx={1.5} {...p} />
          <Rect x={13} y={4} width={7} height={7} rx={1.5} {...p} />
          <Rect x={4} y={13} width={7} height={7} rx={1.5} {...p} />
          <Rect x={13} y={13} width={7} height={7} rx={1.5} {...p} />
        </>
      )}
      {name === 'plus' && <Path d="M12 5v14M5 12h14" {...p} strokeWidth={2.2} />}
      {name === 'close' && <Path d="M6 6l12 12M18 6L6 18" {...p} />}
      {name === 'sparkle' && (
        <Path d="M12 3c.6 4.2 2.8 6.4 7 7-4.2.6-6.4 2.8-7 7-.6-4.2-2.8-6.4-7-7 4.2-.6 6.4-2.8 7-7z" fill={color} />
      )}
      {name === 'select' && (
        <>
          <Circle cx={12} cy={12} r={8.5} {...p} />
          <Path d="M8.5 12.2l2.4 2.4 4.6-4.8" {...p} />
        </>
      )}
      {name === 'info' && (
        <>
          <Circle cx={12} cy={12} r={8.5} {...p} />
          <Path d="M12 11v5M12 8h.01" {...p} />
        </>
      )}
      {name === 'wand' && (
        <>
          <Path d="M5 19L15.5 8.5M13.5 6.5l4 4" {...p} />
          <Path d="M18 3v3M16.5 4.5h3M7 4v2M6 5h2" {...p} />
        </>
      )}
    </Svg>
  );
};

export default Icon;
