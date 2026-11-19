import React, { createContext, useCallback, useContext, useRef, useState } from 'react';
import { Animated, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Icon, { type IconName } from './Icon';
import { Colors, Fonts, Radius, Spacing } from '../theme';

type ToastInput = { message: string; icon?: IconName; tone?: 'default' | 'error' };
type ToastContextValue = { show: (toast: ToastInput) => void };

const ToastContext = createContext<ToastContextValue>({ show: () => {} });

export const useToast = () => useContext(ToastContext);

/** Short, non-blocking feedback ("Saved to Photos") instead of alerts. */
export const ToastProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const insets = useSafeAreaInsets();
  const [toast, setToast] = useState<ToastInput | null>(null);
  const opacity = useRef(new Animated.Value(0)).current;
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const show = useCallback(
    (next: ToastInput) => {
      if (timer.current) clearTimeout(timer.current);
      setToast(next);
      Animated.timing(opacity, { toValue: 1, duration: 160, useNativeDriver: true }).start();
      timer.current = setTimeout(() => {
        Animated.timing(opacity, { toValue: 0, duration: 200, useNativeDriver: true }).start(
          () => setToast(null),
        );
      }, 2200);
    },
    [opacity],
  );

  return (
    <ToastContext.Provider value={{ show }}>
      {children}
      {toast && (
        <View pointerEvents="none" style={[styles.wrap, { top: insets.top + 70 }]}>
          <Animated.View
            accessibilityLiveRegion="polite"
            style={[
              styles.toast,
              toast.tone === 'error' && styles.error,
              {
                opacity,
                transform: [
                  { translateY: opacity.interpolate({ inputRange: [0, 1], outputRange: [-8, 0] }) },
                ],
              },
            ]}>
            {toast.icon && (
              <Icon
                name={toast.icon}
                size={18}
                color={toast.tone === 'error' ? Colors.text : Colors.onAccent}
              />
            )}
            <Text style={[styles.text, toast.tone === 'error' && styles.errorText]}>
              {toast.message}
            </Text>
          </Animated.View>
        </View>
      )}
    </ToastContext.Provider>
  );
};

const styles = StyleSheet.create({
  wrap: { position: 'absolute', left: 0, right: 0, alignItems: 'center' },
  toast: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.sm,
    backgroundColor: Colors.accent,
    borderRadius: Radius.pill,
    paddingHorizontal: Spacing.lg,
    paddingVertical: 10,
    maxWidth: '90%',
  },
  error: { backgroundColor: Colors.danger },
  text: { fontFamily: Fonts.medium, fontSize: 14, color: Colors.onAccent },
  errorText: { color: Colors.text },
});
