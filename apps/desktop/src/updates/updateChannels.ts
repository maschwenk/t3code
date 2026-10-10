import type { DesktopUpdateChannel } from "@t3tools/contracts";

const NIGHTLY_VERSION_PATTERN = /^[^-+]+-nightly\.\d{8}\.\d+$/;
// Preview builds are the maintainers' test train, cut by hand from unreleased
// branches to exercise the release flow. They share nightly's branding but
// are packaged without an update feed (see
// isDesktopPreviewVersion in scripts/build-desktop-artifact.ts), so the
// channel a preview install reports is cosmetic: it never checks for updates
// and no updater feed ever lists a preview release.
const PRERELEASE_VERSION_PATTERN = /^[^-+]+-(?:nightly|preview)\.\d{8}\.\d+$/;
// Fork builds are personal daily-driver builds of a fork of this repository,
// cut by scripts/install-fork-desktop.ts. They get their own branding and
// bundle id so they can sit next to a stable install, and ship without an
// update feed so nothing can replace them with an upstream release.
const FORK_VERSION_PATTERN = /^[^-+]+-fork\.\d{8}\.[0-9a-f]+$/;

export function isNightlyDesktopVersion(version: string): boolean {
  return PRERELEASE_VERSION_PATTERN.test(version);
}

export function isForkDesktopVersion(version: string): boolean {
  return FORK_VERSION_PATTERN.test(version);
}

export function resolveDefaultDesktopUpdateChannel(appVersion: string): DesktopUpdateChannel {
  return NIGHTLY_VERSION_PATTERN.test(appVersion) ? "nightly" : "latest";
}
