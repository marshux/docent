import type { Artwork, ChatMessage } from "./claude";

/**
 * Longest edge sent to Claude. Phone photos are far larger than vision needs, and image cost
 * scales with pixel area; this keeps enough detail to read a wall label.
 */
const MAX_LONG_EDGE = 1568;

export interface PreparedPhoto {
  /** Base64 JPEG without the data-URL prefix, as the API wants it. */
  base64: string;
  /** The same JPEG as a data URL, for showing on the page. */
  dataUrl: string;
}

/** Downscales a chosen photo and re-encodes it as JPEG (which also bakes in its orientation). */
export async function preparePhoto(file: File): Promise<PreparedPhoto> {
  const objectUrl = URL.createObjectURL(file);
  try {
    const image = new Image();
    image.src = objectUrl;
    await image.decode();

    const scale = Math.min(1, MAX_LONG_EDGE / Math.max(image.naturalWidth, image.naturalHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(image.naturalWidth * scale);
    canvas.height = Math.round(image.naturalHeight * scale);
    const context = canvas.getContext("2d");
    if (!context || !canvas.width || !canvas.height) throw new Error("no canvas");
    context.drawImage(image, 0, 0, canvas.width, canvas.height);

    const dataUrl = canvas.toDataURL("image/jpeg", 0.8);
    return { dataUrl, base64: dataUrl.slice(dataUrl.indexOf(",") + 1) };
  } finally {
    URL.revokeObjectURL(objectUrl);
  }
}

const time = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });
const longDate = new Intl.DateTimeFormat(undefined, { dateStyle: "long", timeStyle: "short" });

export function transcriptMarkdown(artwork: Artwork, messages: ChatMessage[], date = new Date()): string {
  const lines = [`# ${artwork.title}`, ""];
  if (artwork.artist) lines.push(`- Artist: ${artwork.artist}`);
  if (artwork.year) lines.push(`- Year: ${artwork.year}`);
  if (artwork.medium) lines.push(`- Medium: ${artwork.medium}`);
  lines.push(`- Conversation: ${longDate.format(date)}`, "");
  for (const message of messages) {
    if (!message.text) continue;
    lines.push(`**${message.role === "user" ? "You" : "Docent"}** (${time.format(message.date)})`, "", message.text, "");
  }
  return lines.join("\n");
}

export function transcriptFilename(artwork: Artwork, date = new Date()): string {
  const safeTitle = artwork.title.replace(/[/\\:?%*|"<>]/g, " ").replace(/\s+/g, " ").trim();
  return `Docent - ${safeTitle || "Artwork"} - ${date.toISOString().slice(0, 10)}.md`;
}

/** Hands the transcript to the phone's share sheet when there is one, otherwise downloads it. */
export async function exportTranscript(artwork: Artwork, messages: ChatMessage[]): Promise<void> {
  const file = new File([transcriptMarkdown(artwork, messages)], transcriptFilename(artwork), { type: "text/markdown" });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file], title: artwork.title });
      return;
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return; // visitor closed the sheet
    }
  }
  const link = document.createElement("a");
  link.href = URL.createObjectURL(file);
  link.download = file.name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}
