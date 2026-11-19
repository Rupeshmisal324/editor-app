import { StyleSheet } from 'react-native';

/** Dark theme to match the native editor. */
export const Colors = {
  bg: '#0B0B0D',
  surface: '#17171B',
  surfaceHigh: '#222228',
  surfacePress: '#2A2A31',
  border: '#2C2C33',
  heroBorder: '#26262C',
  dot: '#3A3A42',
  text: '#F5F5F7',
  textSecondary: '#A1A1AA',
  textMuted: '#9A9AA4',
  accent: '#FFFFFF',
  onAccent: '#0B0B0D',
  danger: '#FF6B6F',
  success: '#34C759',
  overlay: 'rgba(0,0,0,0.55)',
};

export const Fonts = {
  regular: 'DMSans-Regular',
  medium: 'DMSans-Medium',
  semiBold: 'DMSans-SemiBold',
  bold: 'DMSans-Bold',
};

export const Spacing = { xs: 4, sm: 8, md: 12, lg: 16, xl: 20, xxl: 24, page: 20 };

export const Radius = { sm: 8, md: 14, lg: 20, pill: 100 };

export const Type = StyleSheet.create({
  title: { fontFamily: Fonts.bold, fontSize: 30, color: Colors.text, letterSpacing: -0.5 },
  heading: { fontFamily: Fonts.semiBold, fontSize: 18, color: Colors.text },
  cardTitle: { fontFamily: Fonts.semiBold, fontSize: 16, color: Colors.text },
  body: { fontFamily: Fonts.regular, fontSize: 14, color: Colors.textSecondary },
  label: { fontFamily: Fonts.medium, fontSize: 15, color: Colors.text },
  caption: { fontFamily: Fonts.regular, fontSize: 12, color: Colors.textMuted },
});
