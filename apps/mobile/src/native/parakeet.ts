import { requireOptionalNativeModule } from "expo";

export type ParakeetModelStatus =
  | { readonly state: "missing" | "ready" }
  /** No progress once the files are in and the model is being compiled for this device. */
  | { readonly state: "downloading"; readonly progress?: number };

export type ParakeetModule = {
  getParakeetModel(): ParakeetModelStatus;
  /** Resolves false when cancelled. A second call joins the download already running. */
  downloadParakeetModel(): Promise<boolean>;
  cancelParakeetModelDownload(): void;
  deleteParakeetModel(): Promise<void>;
  prepareParakeet(): Promise<void>;
  transcribeWithParakeet(uri: string): Promise<string>;
  addListener(
    event: "onParakeetModel",
    listener: (status: ParakeetModelStatus) => void,
  ): { remove(): void };
};

/** Parakeet Ultra's Core ML bundle as FluidAudio downloads it from Hugging Face. */
export const PARAKEET_DOWNLOAD_BYTES = 632_000_000;

const native = requireOptionalNativeModule<Partial<ParakeetModule>>("T3VoiceTranscription");
const hasParakeet = (module: Partial<ParakeetModule> | null): module is ParakeetModule =>
  typeof module?.transcribeWithParakeet === "function";

/** Null on Android and on builds without on-device Parakeet. */
export const parakeet = hasParakeet(native) ? native : null;
