// Preview builds share nightly branding but ship without an update feed.
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
