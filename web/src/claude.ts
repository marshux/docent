import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { z } from "zod";

export const MODELS = [
  { id: "claude-opus-5-5", name: "Claude Opus 5.5", detail: "Most knowledgeable. Best at recognising artworks." },
  { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", detail: "Faster and about half the cost." },
  { id: "claude-haiku-5-5", name: "Claude Haiku 5.5", detail: "Fastest and cheapest. Least reliable at identification." },
] as const;

export type ModelId = (typeof MODELS)[number]["id"];
export const DEFAULT_MODEL: ModelId = "claude-opus-5-5";

/** What Claude returns when asked to identify a photographed artwork. */
export const Identification = z.object({
  /** False when Claude could not name a specific work; `title` is then a description. */
  identified: z.boolean(),
  title: z.string(),
  artist: z.string(),
  year: z.string(),
  medium: z.string(),
  confidence: z.enum(["high", "medium", "low"]),
  /** One or two sentences, shown to the visitor, on why this confidence level. */
  reasoning: z.string(),
  alternatives: z.array(z.object({ title: z.string(), artist: z.string() })),
});
export type Identification = z.infer<typeof Identification>;

/** The artwork the visitor confirmed (possibly after correcting the identification). */
export interface Artwork {
  title: string;
  artist: string;
  year: string;
  medium: string;
  /** How sure the identification was when accepted; null if the visitor typed the details in themselves. */
  confidence: Identification["confidence"] | null;
}

export interface ChatMessage {
  role: "user" | "assistant";
  text: string;
  date: Date;
}

export type ReplyChunk =
  | { type: "text"; text: string }
  /** The first model declined mid-answer and a fallback model is starting over: discard text so far. */
  | { type: "restart" };

/** An error with a message that is safe and useful to show the visitor. */
export class DocentError extends Error {}

function client(apiKey: string): Anthropic {
  // The visitor's own key, used straight from their browser: there is no Docent server to hold it.
  return new Anthropic({ apiKey, dangerouslyAllowBrowser: true });
}

/** If a safety classifier declines, let the API retry on its recommended fallback model (not offered for Haiku). */
function fallbackParams(model: ModelId) {
  return model === "claude-haiku-5-5"
    ? {}
    : { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const };
}

function imageBlock(jpegBase64: string) {
  return {
    type: "image" as const,
    source: { type: "base64" as const, media_type: "image/jpeg" as const, data: jpegBase64 },
  };
}

function friendly(error: unknown): Error {
  if (error instanceof DocentError) return error;
  if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
    return new DocentError("Claude rejected the API key. Check it in Settings.");
  }
  if (error instanceof Anthropic.RateLimitError) {
    return new DocentError("Your API key hit its rate limit. Wait a moment and try again.");
  }
  if (error instanceof Anthropic.APIUserAbortError) {
    return error;
  }
  if (error instanceof Anthropic.APIConnectionError) {
    return new DocentError("Couldn't reach Claude. Check your connection and try again.");
  }
  if (error instanceof Anthropic.APIError) {
    if (error.status === 529) return new DocentError("Claude is overloaded right now. Try again in a moment.");
    return new DocentError(`Claude API error ${error.status ?? ""}: ${error.message}`);
  }
  return error instanceof Error ? error : new Error(String(error));
}

/** Asks Claude which artwork is in the photo. `titleHint` is whatever the visitor typed, if anything. */
export async function identify(
  apiKey: string,
  model: ModelId,
  jpegBase64: string,
  titleHint: string,
): Promise<Identification> {
  let prompt = `A museum visitor took this photo of an artwork. Identify the specific work.

Use everything visible: the work itself, any signature, and any wall label or caption in the frame.`;
  const hint = titleHint.trim();
  if (hint) {
    prompt += `

The visitor says the title is: "${hint}". Treat that as a strong hint, but check it against what you can see and say so in your reasoning if it does not match.`;
  }
  prompt += `

Confidence levels:
- high: you recognise this exact work.
- medium: probably this work, but it could be another version, a copy, or a similar piece by the same artist.
- low: you are inferring from style or subject and could easily be wrong.

If you cannot name a specific work, set identified to false, put a short description in title (for example "Unidentified Dutch still life"), and give your best guess at the artist or "Unknown".
Use an empty string for a year or medium you do not know rather than guessing.
When confidence is not high, list up to three other works it could plausibly be in alternatives; otherwise leave it empty.
Keep reasoning to one or two plain sentences; it is shown to the visitor.`;

  try {
    const response = await client(apiKey).beta.messages.parse({
      model,
      max_tokens: 16000,
      ...fallbackParams(model),
      output_config: { effort: "medium", format: betaZodOutputFormat(Identification) },
      messages: [{ role: "user", content: [imageBlock(jpegBase64), { type: "text", text: prompt }] }],
    });
    // A declined request is an HTTP 200 with stop_reason "refusal": check before reading the output.
    if (response.stop_reason === "refusal") throw new DocentError("Claude declined to identify that photo.");
    if (response.stop_reason === "max_tokens" || !response.parsed_output) {
      throw new DocentError("Claude's answer came back incomplete. Try again.");
    }
    return response.parsed_output;
  } catch (error) {
    throw friendly(error);
  }
}

export function guideInstructions(artwork: Artwork): string {
  let details = `"${artwork.title}"`;
  if (artwork.artist) details += ` by ${artwork.artist}`;
  if (artwork.year) details += `, ${artwork.year}`;
  if (artwork.medium) details += `, ${artwork.medium}`;

  const certainty = {
    high: "The identification was made from the photo with high confidence and the visitor confirmed it.",
    medium:
      "The identification from the photo was only moderately confident; the visitor accepted it, but it could be a different version or a similar work.",
    low: "The identification from the photo was a low-confidence guess that the visitor accepted. Be open about that when it matters.",
    typed: "The visitor supplied or corrected these details themselves, so trust them over your own reading of the photo.",
  }[artwork.confidence ?? "typed"];

  return `You are Docent, a warm and knowledgeable museum guide. A visitor is standing in front of an artwork and talking with you out loud. Everything you write is read to them by a speech synthesizer.

The artwork: ${details}. ${certainty} The visitor's photo of it is attached to the first message.

Because your words are spoken aloud:
- Write the way a good guide talks: plain sentences, no markdown, lists, headings or emoji, since those would be read out literally.
- Keep each answer to about three to five sentences unless the visitor asks for more. They can always ask a follow-up.

What the visitor wants is the history around this piece: who made it and why, what was happening at the time, how it was made, where it has been, and how people reacted to it. Point out details they can see in front of them.

Being right matters more than telling a good story. If you are unsure of a date, an attribution or an anecdote, say so rather than filling the gap, and do not invent provenance.

The visitor's questions come through speech recognition, so they may contain misheard words. Read them charitably, and ask if a question really does not make sense.`;
}

/** Streams Claude's next reply. `turns` is the conversation so far, ending with the visitor's latest message. */
export async function* streamReply(
  apiKey: string,
  model: ModelId,
  artwork: Artwork,
  jpegBase64: string,
  turns: ChatMessage[],
  signal: AbortSignal,
): AsyncGenerator<ReplyChunk> {
  try {
    const stream = client(apiKey).beta.messages.stream(
      {
        model,
        max_tokens: 16000,
        ...fallbackParams(model),
        system: guideInstructions(artwork),
        // The photo and history are resent every turn; cache the growing prefix.
        cache_control: { type: "ephemeral" },
        output_config: { effort: "low" }, // spoken answers: favour responsiveness
        messages: [
          // The photo opens the conversation; the API merges it with the visitor's first question.
          { role: "user", content: [imageBlock(jpegBase64), { type: "text", text: "Here is my photo of the artwork." }] },
          ...turns.filter((turn) => turn.text).map((turn) => ({ role: turn.role, content: turn.text })),
        ],
      },
      { signal },
    );

    for await (const event of stream) {
      if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
        yield { type: "text", text: event.delta.text };
      } else if (event.type === "content_block_start" && event.content_block.type === "fallback") {
        yield { type: "restart" };
      }
    }

    const message = await stream.finalMessage();
    if (message.stop_reason === "refusal") throw new DocentError("Claude declined to answer that.");
    if (message.stop_reason === "max_tokens") throw new DocentError("The answer was cut off before it finished. Try again.");
  } catch (error) {
    throw friendly(error);
  }
}
