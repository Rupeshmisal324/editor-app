import React from 'react';
import { DarkTheme, NavigationContainer, type Theme } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import OnboardingScreen from './screens/OnboardingScreen';
import MainScreen from './screens/MainScreen';
import ResultScreen from './screens/ResultScreen';
import SettingsScreen from './screens/SettingsScreen';
import { Colors } from './theme';

export type RootStackParamList = {
  Onboarding: undefined;
  Main: undefined;
  /** `fresh` = just exported from the editor. */
  Result: { id: string; fresh?: boolean };
  Settings: undefined;
};

const Stack = createNativeStackNavigator<RootStackParamList>();

const theme: Theme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    background: Colors.bg,
    card: Colors.bg,
    text: Colors.text,
    border: Colors.border,
    primary: Colors.accent,
  },
};

const RootNavigator: React.FC<{ showOnboarding: boolean }> = ({ showOnboarding }) => (
  <NavigationContainer theme={theme}>
    <Stack.Navigator
      initialRouteName={showOnboarding ? 'Onboarding' : 'Main'}
      screenOptions={{
        headerShown: false,
        contentStyle: { backgroundColor: Colors.bg },
        animation: 'slide_from_right',
      }}>
      <Stack.Screen name="Onboarding" component={OnboardingScreen} options={{ animation: 'fade' }} />
      <Stack.Screen name="Main" component={MainScreen} options={{ animation: 'fade' }} />
      <Stack.Screen name="Result" component={ResultScreen} />
      <Stack.Screen name="Settings" component={SettingsScreen} />
    </Stack.Navigator>
  </NavigationContainer>
);

export default RootNavigator;
