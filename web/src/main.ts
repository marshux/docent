import {
  DEFAULT_MODEL,
  MODELS,
  identify,
  streamReply,
  type Artwork,
  type ChatMessage,
  type Identification,
  type ModelId,
} from "./claude";
import { exportTranscript, preparePhoto, type PreparedPhoto } from "./media";
import { Listener, Speaker } from "./speech";

// ---- Saved settings (this browser only) ----

const KEY_STORAGE = "docent.apiKey";
const MODEL_STORAGE = "docent.model";
const SPEAK_STORAGE = "docent.speak";

/** localStorage can throw (private windows, blocked site data); settings then just don't persist. */
const store = {
  get(key: string): string | null {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key: string, value: string | null): void {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch {
      // not persisted; the in-memory value still works for this visit
    }
  },
};

// ---- State ----

type Screen = "setup" | "capture" | "confirm" | "chat";

let apiKey = store.get(KEY_STORAGE) ?? "";
let model: ModelId = MODELS.find((m) => m.id === store.get(MODEL_STORAGE))?.id ?? DEFAULT_MODEL;
let speakReplies = store.get(SPEAK_STORAGE) !== "off";

let photo: PreparedPhoto | null = null;
let identification: Identification | null = null;
/** True once the visitor types over the suggested details or picks an alternative. */
let detailsEdited = false;
let artwork: Artwork | null = null;
let messages: ChatMessage[] = [];
let replyAbort: AbortController | null = null;

const speaker = new Speaker();
const listener = new Listener();

// ---- Elements ----

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`missing #${id}`);
  return node as T;
}

const screens: Record<Screen, HTMLElement> = {
  setup: el("screen-setup"),
  capture: el("screen-capture"),
  confirm: el("screen-confirm"),
  chat: el("screen-chat"),
};
const openSettings = el<HTMLButtonElement>("open-settings");
const settings = el<HTMLDialogElement>("settings");
const modelSelect = el<HTMLSelectElement>("model-select");
const modelDetail = el("model-detail");
const speakToggle = el<HTMLInputElement>("speak-toggle");
const errorBox = el("error");

const keyInput = el<HTMLInputElement>("key-input");
const titleHint = el<HTMLInputElement>("title-hint");
const photoInput = el<HTMLInputElement>("photo-input");
const captureStatus = el("capture-status");

const artFields = {
  title: el<HTMLInputElement>("art-title"),
  artist: el<HTMLInputElement>("art-artist"),
  year: el<HTMLInputElement>("art-year"),
  medium: el<HTMLInputElement>("art-medium"),
};
const alternatives = el("alternatives");
const alternativesList = el("alternatives-list");

const messageList = el<HTMLOListElement>("messages");
const heard = el("heard");
const mic = el<HTMLButtonElement>("mic");
const micLabel = el("mic-label");
const askInput = el<HTMLInputElement>("ask-input");
const toggleVoice = el<HTMLButtonElement>("toggle-voice");

// ---- Shared UI ----

function show(screen: Screen): void {
  for (const [name, node] of Object.entries(screens)) node.hidden = name !== screen;
  openSettings.hidden = screen === "setup";
  window.scrollTo(0, 0);
}

let errorTimer: number | undefined;
function showError(message: string): void {
  errorBox.textContent = message;
  errorBox.hidden = false;
  window.clearTimeout(errorTimer);
  errorTimer = window.setTimeout(() => (errorBox.hidden = true), 7000);
}
errorBox.addEventListener("click", () => (errorBox.hidden = true));

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// ---- Setup and settings ----

el<HTMLFormElement>("key-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const key = keyInput.value.trim();
  if (!key) return;
  apiKey = key;
  store.set(KEY_STORAGE, key);
  keyInput.value = "";
  show("capture");
});

for (const option of MODELS) modelSelect.add(new Option(option.name, option.id));

function renderSettings(): void {
  modelSelect.value = model;
  modelDetail.textContent = MODELS.find((m) => m.id === model)?.detail ?? "";
  speakToggle.checked = speakReplies;
  toggleVoice.textContent = speakReplies ? "Mute" : "Unmute";
}

function setSpeakReplies(on: boolean): void {
  speakReplies = on;
  store.set(SPEAK_STORAGE, on ? "on" : "off");
  if (!on) speaker.stop();
  renderSettings();
}

openSettings.addEventListener("click", () => {
  renderSettings();
  settings.showModal();
});
modelSelect.addEventListener("change", () => {
  model = modelSelect.value as ModelId;
  store.set(MODEL_STORAGE, model);
  renderSettings();
});
speakToggle.addEventListener("change", () => setSpeakReplies(speakToggle.checked));
toggleVoice.addEventListener("click", () => setSpeakReplies(!speakReplies));
el("remove-key").addEventListener("click", () => {
  apiKey = "";
  store.set(KEY_STORAGE, null);
  settings.close();
  startOver();
  show("setup");
});

// ---- 1. Photo ----

photoInput.addEventListener("change", async () => {
  const file = photoInput.files?.[0];
  photoInput.value = ""; // so choosing the same photo again still fires "change"
  if (!file) return;

  captureStatus.hidden = false;
  try {
    photo = await preparePhoto(file).catch(() => {
      throw new Error("Couldn't read that photo. Try another one.");
    });
    identification = await identify(apiKey, model, photo.base64, titleHint.value);
    renderConfirm(photo, identification);
    show("confirm");
  } catch (error) {
    showError(describe(error));
  } finally {
    captureStatus.hidden = true;
  }
});

// ---- 2. Confirm ----

const BADGES: Record<Identification["confidence"], string> = {
  high: "Confident match",
  medium: "Likely match",
  low: "Best guess",
};

function renderConfirm(shown: PreparedPhoto, result: Identification): void {
  el<HTMLImageElement>("confirm-photo").src = shown.dataUrl;
  const badge = el("confidence-badge");
  badge.textContent = result.identified ? BADGES[result.confidence] : "Not identified";
  badge.dataset.level = result.identified ? result.confidence : "none";
  el("confidence-reason").textContent = result.reasoning;

  artFields.title.value = result.title;
  artFields.artist.value = result.artist;
  artFields.year.value = result.year;
  artFields.medium.value = result.medium;
  detailsEdited = false;

  alternatives.hidden = result.alternatives.length === 0;
  alternativesList.replaceChildren(
    ...result.alternatives.map((alternative) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "secondary alternative";
      const title = document.createElement("span");
      title.textContent = alternative.title;
      const artist = document.createElement("span");
      artist.className = "note";
      artist.textContent = alternative.artist;
      button.append(title, artist);
      button.addEventListener("click", () => {
        artFields.title.value = alternative.title;
        artFields.artist.value = alternative.artist;
        artFields.year.value = "";
        artFields.medium.value = "";
        detailsEdited = true;
      });
      return button;
    }),
  );
}

for (const field of Object.values(artFields)) {
  field.addEventListener("input", () => (detailsEdited = true));
}

el<HTMLFormElement>("confirm-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const title = artFields.title.value.trim();
  if (!title || !identification) return;
  artwork = {
    title,
    artist: artFields.artist.value.trim(),
    year: artFields.year.value.trim(),
    medium: artFields.medium.value.trim(),
    confidence: detailsEdited ? null : identification.confidence,
  };
  messages = [];
  messageList.replaceChildren();
  el("chat-title").textContent = artwork.title;
  el("chat-subtitle").textContent = [artwork.artist, artwork.year].filter(Boolean).join(", ");
  renderSettings();
  renderMic();
  show("chat");
  speaker.unlock(); // this tap is the gesture that lets the first answer be spoken
  void respond("Tell me about this piece.");
});

el("retake").addEventListener("click", startOver);

function startOver(): void {
  replyAbort?.abort();
  speaker.stop();
  listener.cancel();
  photo = null;
  identification = null;
  artwork = null;
  messages = [];
  titleHint.value = "";
  show(apiKey ? "capture" : "setup");
}

// ---- 3. Conversation ----

function addBubble(message: ChatMessage): HTMLElement {
  const item = document.createElement("li");
  item.className = `bubble ${message.role}`;
  item.textContent = message.text || "…";
  messageList.append(item);
  item.scrollIntoView({ block: "end" });
  return item;
}

function renderMic(): void {
  const busy = replyAbort !== null;
  mic.hidden = !listener.supported;
  el("mic-unsupported").hidden = listener.supported;
  mic.classList.toggle("listening", listener.listening);
  mic.disabled = busy && !listener.listening;
  micLabel.textContent = listener.listening ? "Tap to send" : busy ? "Answering…" : "Tap to talk";
  if (!listener.listening) heard.hidden = true;
}

async function respond(text: string): Promise<void> {
  const question = text.trim();
  if (!question || !artwork || !photo || replyAbort) return;

  speaker.stop();
  const asked: ChatMessage = { role: "user", text: question, date: new Date() };
  messages.push(asked);
  addBubble(asked);
  const history = [...messages];

  const reply: ChatMessage = { role: "assistant", text: "", date: new Date() };
  const bubble = addBubble(reply);
  const abort = new AbortController();
  replyAbort = abort;
  renderMic();

  try {
    for await (const chunk of streamReply(apiKey, model, artwork, photo.base64, history, abort.signal)) {
      if (chunk.type === "text") {
        reply.text += chunk.text;
        if (speakReplies) speaker.feed(chunk.text);
      } else {
        reply.text = "";
        speaker.stop();
      }
      bubble.textContent = reply.text || "…";
      bubble.scrollIntoView({ block: "end" });
    }
    if (speakReplies) speaker.finish();
    messages.push(reply);
  } catch (error) {
    // A partial answer that was refused, cut off or cancelled is not kept as if it were complete.
    bubble.remove();
    speaker.stop();
    if (!abort.signal.aborted) showError(describe(error));
  } finally {
    if (replyAbort === abort) replyAbort = null;
    renderMic();
  }
}

mic.addEventListener("click", () => {
  if (listener.listening) {
    listener.stop(); // onEnd below sends what was heard
    return;
  }
  speaker.stop(); // talking over the guide interrupts it
  speaker.unlock();
  heard.textContent = "Listening…";
  heard.hidden = false;
  listener.start({
    onText: (text) => (heard.textContent = text || "Listening…"),
    onEnd: (text, error) => {
      renderMic();
      if (error) showError(error);
      else void respond(text);
    },
  });
  renderMic();
});

el<HTMLFormElement>("ask-form").addEventListener("submit", (event) => {
  event.preventDefault();
  if (replyAbort) return;
  const question = askInput.value;
  askInput.value = "";
  speaker.unlock();
  void respond(question);
});

el("export").addEventListener("click", () => {
  if (!artwork || messages.length === 0) {
    showError("There's nothing to export yet.");
    return;
  }
  void exportTranscript(artwork, messages);
});

el("new-artwork").addEventListener("click", startOver);

// ---- Start ----

renderSettings();
show(apiKey ? "capture" : "setup");
