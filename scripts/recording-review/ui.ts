import i18next from "i18next";
import type { Sample, Feedback } from "./server";
const en = {
  local: "LOCAL RECORDING REVIEW",
  title: "Review your recordings",
  privacy: "Local snapshots only. No remote models or audio requests.",
  recording: "Recording",
  previous: "Previous",
  next: "Next",
  original: "Original transcription",
  processed: "Processed result",
  suggestions: "Provisional text comparison",
  provisional:
    "These suggestions compare existing text only. They do not verify audio. Listen before judging or entering a reference transcript.",
  changed:
    "The processed text differs. Check whether it preserves your intended meaning.",
  same: "The existing texts match. Check the audio for recognition errors.",
  missing: "No history is available. Listen and enter a reference if you wish.",
  noProcessed:
    "No processed result is available. Check the original text against the audio.",
  judgment: "Judgment",
  unreviewed: "Unreviewed",
  confirmed: "Confirm suggestion",
  rejected: "Reject suggestion",
  uncertain: "Uncertain",
  reference: "Reference transcript",
  preferred: "Preferred output (optional)",
  notes: "Notes",
  save: "Save",
  saved: "Saved locally",
  saving: "Saving…",
  failure: "Save failed. Changes remain unsaved.",
  loadingFailure: "Could not load recordings. Restart the server and reload.",
  empty: "No recordings found in either app directory.",
  discard: "Discard unsaved changes and switch recordings?",
  unsaved: "Unsaved changes",
  unavailable: "Unavailable",
  progress: "{{reviewed}} / {{total}} reviewed",
};
const zh: typeof en = {
  local: "本地录音审阅",
  title: "逐条听，逐条确认",
  privacy: "仅使用本地快照，不调用远程模型，不上传音频。",
  recording: "录音",
  previous: "上一条",
  next: "下一条",
  original: "原始转写",
  processed: "处理结果",
  suggestions: "临时文字比较建议",
  provisional:
    "建议只比较已有文字，未经音频验证。请先听录音，再判断或填写参考转写。",
  changed: "处理结果与原始文字不同，请检查是否保留了你想表达的意思。",
  same: "已有文字一致，请听录音检查识别是否有误。",
  missing: "没有对应的历史记录。可以听录音后填写参考转写。",
  noProcessed: "没有处理结果，请对照音频检查原始转写。",
  judgment: "判断",
  unreviewed: "未审阅",
  confirmed: "确认建议",
  rejected: "拒绝建议",
  uncertain: "不确定",
  reference: "参考转写",
  preferred: "期望输出（可选）",
  notes: "备注",
  save: "保存",
  saved: "已保存到本地",
  saving: "正在保存…",
  failure: "保存失败，修改仍未保存",
  loadingFailure: "无法加载录音，请重启服务器并刷新。",
  empty: "两个应用目录中都没有找到录音。",
  discard: "放弃未保存的修改并切换录音？",
  unsaved: "有未保存的修改",
  unavailable: "无",
  progress: "{{reviewed}} / {{total}} 已审阅",
};
await i18next.init({
  lng: "zh",
  fallbackLng: "en",
  resources: { en: { translation: en }, zh: { translation: zh } },
});
const t = (key: keyof typeof en) => i18next.t(key);
function element<T extends HTMLElement>(selector: string): T {
  const found = document.querySelector<T>(selector);
  if (!found) throw new Error("Missing UI element");
  return found;
}
for (const node of document.querySelectorAll<HTMLElement>("[data-t]"))
  node.textContent = t(node.dataset.t as keyof typeof en);
document.title = t("title");
const select = element<HTMLSelectElement>("#sample");
const judgment = element<HTMLSelectElement>("#judgment");
const reference = element<HTMLTextAreaElement>("#reference");
const preferred = element<HTMLTextAreaElement>("#preferred");
const notes = element<HTMLTextAreaElement>("#notes");
const status = element("#status");
const previous = element<HTMLButtonElement>("#previous");
const next = element<HTMLButtonElement>("#next");
const save = element<HTMLButtonElement>("#save");
const form = element<HTMLFormElement>("form");
const audio = element<HTMLAudioElement>("audio");
type ReviewSample = Sample & { feedback: Feedback | null };
let samples: ReviewSample[] = [];
let index = 0;
let dirty = false;
let saving = false;
function updateProgress() {
  element("#progress").textContent = i18next.t("progress", {
    reviewed: samples.filter(
      (sample) => sample.feedback && sample.feedback.judgment !== "unreviewed",
    ).length,
    total: samples.length,
  });
}
function render() {
  const sample = samples[index];
  select.value = String(index);
  previous.disabled = index === 0;
  next.disabled = index === samples.length - 1;
  audio.src = "/audio/" + sample.id;
  element("#original").textContent = sample.transcription ?? t("unavailable");
  element("#processed").textContent = sample.processed ?? t("unavailable");
  element("#suggestion").textContent = t(
    sample.transcription === null
      ? "missing"
      : sample.processed === null
        ? "noProcessed"
        : sample.transcription === sample.processed
          ? "same"
          : "changed",
  );
  const feedback = sample.feedback;
  judgment.value = feedback?.judgment ?? "unreviewed";
  reference.value = feedback?.reference ?? "";
  preferred.value = feedback?.preferred ?? "";
  notes.value = feedback?.notes ?? "";
  dirty = false;
  status.textContent = "";
  updateProgress();
}
function navigate(target: number) {
  if (saving || target < 0 || target >= samples.length || target === index) {
    select.value = String(index);
    return;
  }
  if (dirty && !window.confirm(t("discard"))) {
    select.value = String(index);
    return;
  }
  index = target;
  render();
}
select.addEventListener("change", () => navigate(Number(select.value)));
previous.addEventListener("click", () => navigate(index - 1));
next.addEventListener("click", () => navigate(index + 1));
form.addEventListener("input", () => {
  dirty = true;
  status.textContent = t("unsaved");
});
window.addEventListener("beforeunload", (event) => {
  if (dirty || saving) {
    event.preventDefault();
    event.returnValue = "";
  }
});
form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (saving || !samples.length) return;
  const feedback: Feedback = {
    judgment: judgment.value as Feedback["judgment"],
    reference: reference.value,
    preferred: preferred.value,
    notes: notes.value,
  };
  saving = true;
  for (const control of [
    select,
    previous,
    next,
    save,
    judgment,
    reference,
    preferred,
    notes,
  ])
    control.disabled = true;
  status.textContent = t("saving");
  try {
    const result = await fetch("/api/feedback/" + samples[index].id, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(feedback),
    });
    if (!result.ok) throw new Error("Save failed");
    samples[index].feedback = feedback;
    dirty = false;
    status.textContent = t("saved");
    updateProgress();
  } catch {
    status.textContent = t("failure");
  } finally {
    saving = false;
    for (const control of [select, save, judgment, reference, preferred, notes])
      control.disabled = false;
    previous.disabled = index === 0;
    next.disabled = index === samples.length - 1;
  }
});
try {
  const result = await fetch("/api/samples");
  if (!result.ok) throw new Error("Load failed");
  samples = (await result.json()) as ReviewSample[];
  for (const [i, sample] of samples.entries()) {
    const option = document.createElement("option");
    option.value = String(i);
    option.textContent = `${i + 1}. ${sample.source} · ${sample.fileName}`;
    select.append(option);
  }
  if (samples.length) render();
  else {
    status.textContent = t("empty");
    form.hidden = true;
    audio.hidden = true;
    select.disabled = true;
    previous.disabled = true;
    next.disabled = true;
    updateProgress();
  }
} catch {
  status.textContent = t("loadingFailure");
  form.hidden = true;
}
