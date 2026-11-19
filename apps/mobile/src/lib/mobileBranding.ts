export type MobileStageLabel = "Fork" | "Dev" | "Nightly";

export function resolveMobileStageLabel(appVariant: unknown): MobileStageLabel {
  if (appVariant === "development") return "Dev";
  if (appVariant === "preview") return "Nightly";
  return "Fork";
}

/** "FORK · 15c541a": the stage, plus the commit app.config.ts baked into the bundle when it had one. */
export function formatMobileStageBadge(
  stage: MobileStageLabel,
  commitSha: string | undefined,
): string {
  const label = stage.toUpperCase();
  return commitSha ? `${label} · ${commitSha}` : label;
}
