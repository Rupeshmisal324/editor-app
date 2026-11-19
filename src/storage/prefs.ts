import AsyncStorage from '@react-native-async-storage/async-storage';

const ONBOARDED = 'editor.onboarded.v1';

export const hasOnboarded = async (): Promise<boolean> => {
  try {
    return (await AsyncStorage.getItem(ONBOARDED)) === '1';
  } catch {
    return false;
  }
};

export const setOnboarded = async (done: boolean) => {
  try {
    if (done) await AsyncStorage.setItem(ONBOARDED, '1');
    else await AsyncStorage.removeItem(ONBOARDED);
  } catch {
    // Non-critical: the intro just shows again.
  }
};
