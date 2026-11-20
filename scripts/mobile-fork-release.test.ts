import { expect, it } from "vite-plus/test";

import { releaseEnvironment } from "./mobile-fork-release.ts";

it("builds and publishes from the release file, not the shell's app-config variables", () => {
  const env = releaseEnvironment(
    {
      PATH: "/usr/bin",
      EXPO_TOKEN: "robot-token",
      // A T3 Code shell exports these; in the config they would change the fingerprint.
      T3CODE_RELAY_URL: "https://relay.shell.example",
      T3CODE_MOBILE_VERSION: "9.0.0",
      EXPO_PUBLIC_OTLP_TRACES_URL: "https://traces.example",
      APP_VARIANT: "development",
    },
    "APP_VARIANT=production\nT3CODE_RELAY_URL=https://relay.example\n",
  );
  expect(env).toEqual({
    PATH: "/usr/bin",
    EXPO_TOKEN: "robot-token",
    APP_VARIANT: "production",
    T3CODE_RELAY_URL: "https://relay.example",
  });
});
