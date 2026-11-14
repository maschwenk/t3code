import { useAtomValue } from "@effect/atom-react";
import {
  configuredSecretSources,
  secretRequestReference,
} from "@t3tools/client-runtime/secret-request";
import { setCloudSpeechKey } from "@t3tools/client-runtime/voice-input";
import {
  AuthSettingsWriteScope,
  CloudSpeechApiKey,
  isSecretReference,
  type SecretProviderId,
  type SettingsSecretValue,
} from "@t3tools/contracts";
import * as Schema from "effect/Schema";
import Constants from "expo-constants";
import { useState } from "react";
import { ScrollView, TextInput, View } from "react-native";

import { AppText as Text } from "../../components/ui/AppText";
import { Chip } from "../../components/ui/Chip";
import * as Dialog from "../../components/ui/Dialog";
import { ListActionRow } from "../../components/ui/ListActionRow";
import { Sheet } from "../../components/ui/Sheet";
import type { EnvironmentPresentation } from "../../state/environments";
import { useEnvironmentScope } from "../../state/session";
import { readAloudConnectionAtom, runSpeech } from "../voice-input/voiceDestination";
import { SettingsSection } from "./components/SettingsSection";

const isApiKey = Schema.is(CloudSpeechApiKey);

/** The environment speaks replies aloud, so its ElevenLabs key picks the voice for every device. */
export function ReadAloudVoiceSection({ environment }: { environment: EnvironmentPresentation }) {
  const [open, setOpen] = useState(false);
  const canManage = useEnvironmentScope(environment.environmentId, AuthSettingsWriteScope);
  const saved = Boolean(environment.serverConfig?.settings.cloudSpeechCredentials?.elevenlabs);
  return (
    <SettingsSection title={`Read aloud on ${environment.label}`}>
      <ListActionRow
        label="ElevenLabs voice"
        description={
          saved
            ? "On · replies you play are spoken by ElevenLabs"
            : canManage
              ? "Off · add an API key to replace Kokoro"
              : "Off · replies are spoken by Kokoro"
        }
        disabled={!canManage}
        onPress={() => setOpen(true)}
      />
      {open && (
        <ElevenLabsKeySheet
          environment={environment}
          saved={saved}
          onClose={() => setOpen(false)}
        />
      )}
    </SettingsSection>
  );
}

function ElevenLabsKeySheet({
  environment,
  saved,
  onClose,
}: {
  environment: EnvironmentPresentation;
  saved: boolean;
  onClose: () => void;
}) {
  const connection = useAtomValue(readAloudConnectionAtom(environment.environmentId));
  const existing = environment.serverConfig?.settings.cloudSpeechCredentials?.elevenlabs;
  const sources =
    Constants.expoConfig?.extra?.secretsFeatureEnabled === true &&
    environment.serverConfig?.secretReferences
      ? configuredSecretSources(environment.serverConfig.settings.secretProviders)
      : [];
  const reference =
    isSecretReference(existing) && sources.some((candidate) => candidate.id === existing.provider)
      ? existing
      : null;
  const [sourceId, setSourceId] = useState<SecretProviderId | null>(reference?.provider ?? null);
  const [draft, setDraft] = useState(reference?.reference ?? "");
  const [saving, setSaving] = useState(false);
  const source = sources.find((candidate) => candidate.id === sourceId);
  const credential =
    sourceId !== null
      ? source && secretRequestReference(source, draft)
      : isApiKey(draft.trim())
        ? draft.trim()
        : undefined;

  const save = async (value: SettingsSecretValue | null) => {
    if (!connection || saving) return;
    setSaving(true);
    try {
      await runSpeech(setCloudSpeechKey(connection, "elevenlabs", value));
    } catch {
      setSaving(false);
      Dialog.alert(
        "Could not update the API key",
        "Check the environment connection and your settings permissions.",
      );
      return;
    }
    onClose();
  };

  return (
    <Sheet title="ElevenLabs voice" onClose={onClose} dismissDisabled={saving}>
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        keyboardShouldPersistTaps="handled"
        contentContainerClassName="gap-2 pb-8"
      >
        <Text className="mx-4 text-sm text-foreground-muted">
          When you play a reply, {environment.label} sends its text to ElevenLabs. Anyone who can
          use {environment.label} can bill this key.
        </Text>
        {!connection ? (
          <ListActionRow label="Environment not connected" disabled onPress={() => {}} />
        ) : (
          <>
            {sources.length > 0 && (
              <View className="mx-4 flex-row flex-wrap gap-2">
                <Chip
                  label="Value"
                  size="small"
                  selected={sourceId === null}
                  disabled={saving}
                  onPress={() => {
                    setDraft("");
                    setSourceId(null);
                  }}
                />
                {sources.map((candidate) => (
                  <Chip
                    key={candidate.id}
                    label={candidate.label}
                    size="small"
                    selected={sourceId === candidate.id}
                    disabled={saving}
                    onPress={() => {
                      setDraft("");
                      setSourceId(candidate.id);
                    }}
                  />
                ))}
              </View>
            )}
            <TextInput
              key={sourceId ?? "literal"}
              accessibilityLabel={sourceId ? "ElevenLabs API key reference" : "ElevenLabs API key"}
              placeholder={
                source?.referencePlaceholder ??
                (saved ? "Saved key · enter a new one to replace" : "API key")
              }
              secureTextEntry={sourceId === null}
              autoCapitalize="none"
              autoCorrect={false}
              autoComplete="off"
              importantForAutofill="no"
              maxLength={4096}
              editable={!saving}
              returnKeyType="done"
              onSubmitEditing={() => {
                if (credential) void save(credential);
              }}
              value={draft}
              onChangeText={setDraft}
              className="mx-4 rounded-lg bg-background px-3 py-2 text-foreground"
            />
            <ListActionRow
              label={saved ? "Save key" : "Save and use ElevenLabs"}
              description={
                draft && !credential
                  ? (source?.invalidReferenceMessage ?? "Enter a valid API key.")
                  : "The key needs Text to Speech access."
              }
              disabled={!credential || saving}
              onPress={() => {
                if (credential) void save(credential);
              }}
            />
            {saved && (
              <ListActionRow
                tone="danger"
                label="Remove key from environment"
                disabled={saving}
                onPress={() =>
                  Dialog.confirm({
                    title: `Remove the ElevenLabs key from ${environment.label}?`,
                    message: "Replies go back to Kokoro on that computer.",
                    confirmText: "Remove key",
                    destructive: true,
                    onConfirm: () => void save(null),
                  })
                }
              />
            )}
          </>
        )}
      </ScrollView>
    </Sheet>
  );
}
