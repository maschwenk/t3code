import type { PreparedConnection } from "@t3tools/client-runtime/connection";
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
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import { useId, useState } from "react";
import { isSecretsFeatureEnabled } from "../../env";
import { runEnvironmentSpeech } from "../../speech/runEnvironmentSpeech";
import { useEnvironments, type EnvironmentPresentation } from "../../state/environments";
import { useEnvironmentScope, usePreparedConnection } from "../../state/session";
import { Button } from "../ui/button";
import {
  Dialog,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogPanel,
  DialogPopup,
  DialogTitle,
} from "../ui/dialog";
import { Input } from "../ui/input";
import { Label } from "../ui/label";
import { SecretInput } from "./SecretInput";
import { SecretSourceSelect } from "./SecretSourceInput";
import { SettingsRow, SettingsSection } from "./settingsLayout";
import { searchableSetting } from "./settingsSearch";

const isApiKey = Schema.is(CloudSpeechApiKey);

export function ReadAloudSettings() {
  const { environments } = useEnvironments();
  const speaking = environments.filter(
    (environment) => environment.serverConfig?.environment.capabilities.voiceSynthesis,
  );
  return (
    <SettingsSection id="voice-read-aloud" title="Read aloud">
      {speaking.length === 0 ? (
        <SettingsRow
          {...searchableSetting("read-aloud-voice")}
          description="Connect an environment on macOS, Windows x64, or Linux to hear replies on your phone."
        />
      ) : (
        speaking.map((environment, index) => (
          <ReadAloudVoiceRow
            key={environment.environmentId}
            environment={environment}
            named={speaking.length > 1}
            searchable={index === 0}
          />
        ))
      )}
    </SettingsSection>
  );
}

function ReadAloudVoiceRow({
  environment,
  named,
  searchable,
}: {
  environment: EnvironmentPresentation;
  named: boolean;
  searchable: boolean;
}) {
  const [open, setOpen] = useState(false);
  const canManage = useEnvironmentScope(environment.environmentId, AuthSettingsWriteScope);
  const prepared = Option.getOrNull(usePreparedConnection(environment.environmentId));
  const saved = Boolean(environment.serverConfig?.settings?.cloudSpeechCredentials?.elevenlabs);
  return (
    <>
      <SettingsRow
        {...(searchable ? searchableSetting("read-aloud-voice") : { fork: true })}
        title={named ? `Read-aloud voice on ${environment.label}` : "Read-aloud voice"}
        description={
          saved
            ? `Replies you play on your phone are spoken by ElevenLabs. ${environment.label} sends their text to ElevenLabs with your key.`
            : `Replies you play on your phone are spoken by Kokoro on ${environment.label}. Add an ElevenLabs API key for a more natural voice.`
        }
        control={
          <div className="flex items-center gap-2">
            <span className="text-xs text-muted-foreground">{saved ? "ElevenLabs" : "Kokoro"}</span>
            {canManage && prepared && (
              <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
                {saved ? "Manage key" : "Add key"}
              </Button>
            )}
          </div>
        }
      />
      {open && prepared && (
        <ElevenLabsKeyDialog
          environment={environment}
          prepared={prepared}
          saved={saved}
          close={() => setOpen(false)}
        />
      )}
    </>
  );
}

function ElevenLabsKeyDialog({
  environment,
  prepared,
  saved,
  close,
}: {
  environment: EnvironmentPresentation;
  prepared: PreparedConnection;
  saved: boolean;
  close: () => void;
}) {
  const formId = useId();
  const existing = environment.serverConfig?.settings?.cloudSpeechCredentials?.elevenlabs;
  const sources =
    isSecretsFeatureEnabled && environment.serverConfig?.secretReferences
      ? configuredSecretSources(environment.serverConfig.settings?.secretProviders ?? {})
      : [];
  const reference =
    isSecretReference(existing) && sources.some((s) => s.id === existing.provider)
      ? existing
      : null;
  const [sourceId, setSourceId] = useState<SecretProviderId | null>(reference?.provider ?? null);
  const [draft, setDraft] = useState(reference?.reference ?? "");
  const [remove, setRemove] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const source = sources.find((s) => s.id === sourceId);
  const credential =
    sourceId !== null
      ? source && secretRequestReference(source, draft)
      : isApiKey(draft.trim())
        ? draft.trim()
        : undefined;

  const save = async (value: SettingsSecretValue | null) => {
    if (busy) return;
    setError("");
    setBusy(true);
    try {
      await runEnvironmentSpeech(setCloudSpeechKey(prepared, "elevenlabs", value));
      close();
    } catch {
      setError("Couldn’t save this change. Check your connection and try again.");
      setBusy(false);
    }
  };

  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open && !busy) close();
      }}
    >
      <DialogPopup className="max-w-md" showCloseButton={!busy}>
        <DialogHeader>
          <DialogTitle>
            {remove
              ? "Remove the ElevenLabs key?"
              : saved
                ? "Manage ElevenLabs key"
                : "Read aloud with ElevenLabs?"}
          </DialogTitle>
          <DialogDescription>
            {remove
              ? `Replies played from ${environment.label} go back to Kokoro on that computer.`
              : `When you play a reply, ${environment.label} sends its text to ElevenLabs. Anyone who can use ${environment.label} can bill this key.`}
          </DialogDescription>
        </DialogHeader>
        {!remove && (
          <DialogPanel>
            <form
              id={formId}
              className="grid gap-2"
              onSubmit={(event) => {
                event.preventDefault();
                if (credential !== undefined) void save(credential);
              }}
            >
              <Label htmlFor="read-aloud-key">API key</Label>
              <div className="flex min-w-0 items-start gap-2">
                {sources.length > 0 && (
                  <SecretSourceSelect
                    value={sourceId}
                    sources={sources}
                    label="ElevenLabs API key"
                    disabled={busy}
                    onValueChange={(next) => {
                      setSourceId(next);
                      setDraft("");
                      setError("");
                    }}
                  />
                )}
                <div className="min-w-0 flex-1">
                  {sourceId !== null ? (
                    <Input
                      key={sourceId}
                      id="read-aloud-key"
                      name="reference"
                      aria-label="ElevenLabs API key reference"
                      autoFocus
                      placeholder={source?.referencePlaceholder}
                      value={draft}
                      disabled={busy}
                      autoComplete="off"
                      spellCheck={false}
                      onChange={(event) => setDraft(event.target.value)}
                    />
                  ) : (
                    <SecretInput
                      id="read-aloud-key"
                      name="key"
                      aria-label="ElevenLabs API key"
                      autoFocus
                      placeholder="Enter API key"
                      value={draft}
                      configured={saved && !isSecretReference(existing)}
                      disabled={busy}
                      maxLength={4096}
                      onChange={(event) => setDraft(event.target.value)}
                    />
                  )}
                </div>
              </div>
              <p className="text-sm text-muted-foreground">
                {draft.trim() && !credential
                  ? (source?.invalidReferenceMessage ??
                    "Enter an API key, not a URL or secret reference.")
                  : "The key needs Text to Speech access."}
              </p>
            </form>
          </DialogPanel>
        )}
        {error && (
          <p className="px-6 text-sm text-destructive" role="alert">
            {error}
          </p>
        )}
        <DialogFooter>
          {saved && !remove && (
            <div className="sm:mr-auto">
              <Button
                type="button"
                size="sm"
                variant="ghost"
                disabled={busy}
                onClick={() => setRemove(true)}
              >
                Remove key…
              </Button>
            </div>
          )}
          <Button type="button" size="sm" variant="outline" disabled={busy} onClick={close}>
            Cancel
          </Button>
          {remove ? (
            <Button
              type="button"
              size="sm"
              variant="destructive"
              disabled={busy}
              onClick={() => void save(null)}
            >
              Remove key
            </Button>
          ) : (
            <Button type="submit" form={formId} size="sm" disabled={busy || !credential}>
              {saved ? "Save key" : "Save and use ElevenLabs"}
            </Button>
          )}
        </DialogFooter>
      </DialogPopup>
    </Dialog>
  );
}
