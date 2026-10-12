/** Splits streamed text into whole sentences so each can be spoken as soon as it is complete. */
export class SentenceChunker {
  private buffer = "";

  /** Adds streamed text and returns any sentences that are now complete. */
  append(text: string): string[] {
    this.buffer += text;
    const sentences: string[] = [];
    // a ".", "!" or "?" followed by whitespace ends a sentence ("73.7 cm" does not)
    for (let match = /[.!?](?=\s)/.exec(this.buffer); match; match = /[.!?](?=\s)/.exec(this.buffer)) {
      const sentence = this.buffer.slice(0, match.index + 1).trim();
      this.buffer = this.buffer.slice(match.index + 1);
      if (sentence) sentences.push(sentence);
    }
    return sentences;
  }

  /** Returns whatever is left once the stream has ended. */
  flush(): string | null {
    const rest = this.buffer.trim();
    this.buffer = "";
    return rest || null;
  }
}

/** Reads the guide's reply aloud with the browser's speech synthesis, sentence by sentence as it streams in. */
export class Speaker {
  private chunker = new SentenceChunker();
  readonly supported = "speechSynthesis" in window;

  /**
   * Call from inside a tap handler. Mobile browsers only let a page speak after a user gesture,
   * and the reply arrives later, outside the gesture; a silent utterance here unlocks it.
   */
  unlock(): void {
    if (!this.supported) return;
    const silent = new SpeechSynthesisUtterance("");
    silent.volume = 0;
    speechSynthesis.speak(silent);
  }

  feed(text: string): void {
    for (const sentence of this.chunker.append(text)) this.speak(sentence);
  }

  finish(): void {
    const rest = this.chunker.flush();
    if (rest) this.speak(rest);
  }

  stop(): void {
    this.chunker = new SentenceChunker();
    if (this.supported) speechSynthesis.cancel();
  }

  private speak(sentence: string): void {
    if (!this.supported) return;
    const utterance = new SpeechSynthesisUtterance(sentence);
    utterance.lang = navigator.language || "en-US";
    speechSynthesis.speak(utterance); // queues behind anything already being spoken
  }
}

interface RecognitionLike {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: { results: ArrayLike<ArrayLike<{ transcript: string }>> }) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
  abort(): void;
}

interface ListenHandlers {
  /** Called with everything heard so far, as it is recognised. */
  onText(text: string): void;
  /** Called once when listening ends, whether the visitor stopped it or the browser did. */
  onEnd(text: string, error: string | null): void;
}

/** Turns the visitor's speech into text with the browser's speech recognition (Chrome, Edge, Safari). */
export class Listener {
  private readonly ctor: (new () => RecognitionLike) | undefined;
  private recognition: RecognitionLike | null = null;

  constructor() {
    const scope = window as unknown as Record<string, new () => RecognitionLike>;
    this.ctor = scope.SpeechRecognition ?? scope.webkitSpeechRecognition;
  }

  get supported(): boolean {
    return Boolean(this.ctor);
  }

  get listening(): boolean {
    return this.recognition !== null;
  }

  start(handlers: ListenHandlers): void {
    if (!this.ctor || this.recognition) return;
    const recognition = new this.ctor();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = navigator.language || "en-US";

    let heard = "";
    let failure: string | null = null;
    recognition.onresult = (event) => {
      heard = Array.from(event.results, (result) => result[0].transcript).join(" ").replace(/\s+/g, " ").trim();
      handlers.onText(heard);
    };
    recognition.onerror = (event) => {
      // "no-speech" and "aborted" just mean nothing was said; they are not worth an error message
      if (event.error === "not-allowed" || event.error === "service-not-allowed") {
        failure = "Microphone access was blocked. Allow it for this site, or type your question.";
      } else if (event.error !== "no-speech" && event.error !== "aborted") {
        failure = "Speech recognition stopped unexpectedly. Try again, or type your question.";
      }
    };
    recognition.onend = () => {
      this.recognition = null;
      handlers.onEnd(heard, failure);
    };

    this.recognition = recognition;
    recognition.start();
  }

  /** Stops listening; `onEnd` fires with what was heard. */
  stop(): void {
    this.recognition?.stop();
  }

  /** Stops listening and throws away what was heard. */
  cancel(): void {
    if (!this.recognition) return;
    this.recognition.onend = null;
    this.recognition.abort();
    this.recognition = null;
  }
}
