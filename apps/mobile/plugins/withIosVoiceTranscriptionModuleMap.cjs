const fs = require("node:fs");
const path = require("node:path");

const { withDangerousMod } = require("expo/config-plugins");

const MARKER =
  "# t3code: keep T3VoiceTranscription's module map from claiming the shared products directory";
const MODULE_MAP_REPAIR = `${MARKER}
    # React Native builds every pod that links a Swift package (this one and ClerkExpo) into the
    # shared products directory. Clang rejects two umbrella headers in one directory, and this
    # Swift-only pod has nothing for an umbrella to cover.
    voice_module_map = File.join(installer.sandbox.root, "Target Support Files", "T3VoiceTranscription", "T3VoiceTranscription.modulemap")
    if File.exist?(voice_module_map)
      contents = File.read(voice_module_map)
      repaired = contents.sub("umbrella header", "header").sub(/^\\s*module \\* \\{ export \\* \\}\\n/, "")
      File.write(voice_module_map, repaired) unless repaired == contents
    end
`;

module.exports = function withIosVoiceTranscriptionModuleMap(config) {
  return withDangerousMod(config, [
    "ios",
    (nextConfig) => {
      const podfilePath = path.join(nextConfig.modRequest.platformProjectRoot, "Podfile");
      const podfile = fs.readFileSync(podfilePath, "utf8");

      if (podfile.includes(MARKER)) {
        return nextConfig;
      }

      const postInstallStart = "post_install do |installer|\n";
      if (!podfile.includes(postInstallStart)) {
        throw new Error(
          "Unable to repair T3VoiceTranscription's module map: post_install is missing.",
        );
      }

      fs.writeFileSync(
        podfilePath,
        podfile.replace(postInstallStart, `${postInstallStart}${MODULE_MAP_REPAIR}`),
        "utf8",
      );
      return nextConfig;
    },
  ]);
};
