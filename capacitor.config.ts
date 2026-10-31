import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.zinoagent.app',
  appName: 'ZinoAgent',
  webDir: 'dist',
  ios: {
    contentInset: 'never',
    backgroundColor: '#00000000',
    // Allow the web view to scroll only where our layout lets it.
    scrollEnabled: false,
    limitsNavigationsToAppBoundDomains: false,
  },
  plugins: {
    // CapacitorHttp stays disabled: cloud requests go through ZinoHttp so API keys stay native.
    CapacitorHttp: { enabled: false },
  },
};

export default config;
