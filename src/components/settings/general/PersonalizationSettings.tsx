import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import {
  commands,
  type CommonUse,
  type Domain,
  type PersonalizationProfile,
  type PersonalizationStatus,
  type TrialResult,
} from "@/bindings";
import { useSettings } from "@/hooks/useSettings";
import { Dropdown, SettingsGroup } from "@/components/ui";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";

const USES: CommonUse[] = [
  "ai_conversation",
  "messaging",
  "work_documents",
  "notes",
  "study_writing",
  "other",
];
const DOMAINS: Domain[] = [
  "software",
  "product_design",
  "business",
  "marketing",
  "education",
  "healthcare",
  "law",
  "finance",
  "engineering",
  "media",
  "other",
];
const EMPTY: PersonalizationProfile = {
  enabled: false,
  invitation_dismissed: false,
  uses: [],
  domain: null,
  other_domain: "",
};

export function PersonalizationSettings() {
  const { t } = useTranslation();
  const { settings, refreshSettings } = useSettings();
  const profile = settings?.personalization ?? EMPTY;
  const [draft, setDraft] = useState<PersonalizationProfile>(profile);
  const [step, setStep] = useState<"card" | "edit" | "review">("card");
  const [status, setStatus] = useState<PersonalizationStatus | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const [trialPhase, setTrialPhase] = useState<
    "idle" | "starting" | "recording" | "processing"
  >("idle");
  const [trialLocalRoute, setTrialLocalRoute] = useState<boolean | null>(null);
  const [trial, setTrial] = useState<TrialResult | null>(null);
  const trialId = useRef<string | null>(null);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
      if (trialId.current)
        void commands
          .cancelPersonalizationTrial(trialId.current)
          .catch((error: unknown) =>
            console.error("Could not cancel recording trial:", error),
          );
    };
  }, []);
  useEffect(() => {
    let current = true;
    let fetching = false;
    const refresh = async () => {
      if (fetching) return;
      fetching = true;
      try {
        const result = await commands.getPersonalizationStatus();
        if (current) setStatus(result);
      } catch {
        if (current) setStatus(null);
      } finally {
        fetching = false;
      }
    };
    void refresh();
    const timer = settings?.local_polishing_enabled
      ? window.setInterval(() => void refresh(), 500)
      : undefined;
    return () => {
      current = false;
      window.clearInterval(timer);
    };
  }, [settings]);

  const perform = async (
    operation: () => Promise<
      { status: "ok" } | { status: "error"; error: string }
    >,
    next?: () => void,
  ) => {
    setBusy(true);
    setError(false);
    try {
      const result = await operation();
      if (result.status === "error") throw new Error(result.error);
      await refreshSettings(true);
      next?.();
    } catch {
      setError(true);
    } finally {
      setBusy(false);
    }
  };
  const edit = () => {
    setDraft(profile);
    setStep("edit");
    setError(false);
  };
  const startTrial = async () => {
    const id = crypto.getRandomValues(new Uint32Array(4)).join("-");
    trialId.current = id;
    setTrial(null);
    setTrialLocalRoute(null);
    setError(false);
    setTrialPhase("starting");
    try {
      const result = await commands.startPersonalizationTrial(id);
      if (result.status === "error") throw new Error(result.error);
      if (mounted.current && trialId.current === id) {
        setTrialLocalRoute(result.data);
        setTrialPhase("recording");
      }
    } catch {
      if (mounted.current && trialId.current === id) {
        setError(true);
        setTrialPhase("idle");
        trialId.current = null;
      }
    }
  };
  const stopTrial = async () => {
    const id = trialId.current;
    if (!id) return;
    setTrialPhase("processing");
    try {
      const result = await commands.stopPersonalizationTrial(id);
      if (result.status === "error") throw new Error(result.error);
      if (mounted.current && trialId.current === id) setTrial(result.data);
    } catch {
      if (mounted.current && trialId.current === id) setError(true);
    } finally {
      if (mounted.current && trialId.current === id) {
        setTrialPhase("idle");
        trialId.current = null;
      }
    }
  };
  const cancelTrial = async () => {
    const id = trialId.current;
    if (!id) return;
    try {
      const result = await commands.cancelPersonalizationTrial(id);
      if (result.status === "error") throw new Error(result.error);
      trialId.current = null;
      setTrialPhase("idle");
      setError(false);
    } catch {
      setError(true);
    }
  };
  // Match the backend capture deadline so a disappeared page cannot leave the microphone open.
  useEffect(() => {
    if (trialPhase !== "starting" && trialPhase !== "recording") return;
    const timer = window.setTimeout(() => {
      void cancelTrial();
    }, 60_000);
    return () => window.clearTimeout(timer);
  }, [trialPhase]);

  const localPolishing = settings?.local_polishing_enabled ?? false;
  const pending =
    profile.enabled &&
    (localPolishing || settings?.processing_mode === "generated");
  return (
    <SettingsGroup variant="card" title={t("personalization.title")}>
      <div className="space-y-4 py-3">
        <p className="text-sm text-text/70">{t("personalization.intro")}</p>
        {error && (
          <p role="alert" className="text-sm text-red-500">
            {t("personalization.error")}
          </p>
        )}
        {step === "card" ? (
          <>
            <p role="status" className="text-sm">
              {t(
                pending
                  ? status?.active
                    ? localPolishing
                      ? "personalization.localReady"
                      : "personalization.ready"
                    : localPolishing
                      ? "personalization.localPending"
                      : "personalization.pending"
                  : "personalization.disabled",
              )}
            </p>
            <div className="flex flex-wrap gap-2">
              <Button onClick={edit} disabled={busy || trialPhase !== "idle"}>
                {t(
                  profile.invitation_dismissed
                    ? "personalization.edit"
                    : "personalization.setup",
                )}
              </Button>
              {!profile.invitation_dismissed && (
                <Button
                  variant="secondary"
                  disabled={busy}
                  onClick={() =>
                    void perform(() =>
                      commands.dismissPersonalizationInvitation(),
                    )
                  }
                >
                  {t("personalization.later")}
                </Button>
              )}
              {profile.enabled && (
                <Button
                  variant="secondary"
                  disabled={busy || trialPhase !== "idle"}
                  onClick={() =>
                    void perform(() =>
                      commands.savePersonalization({
                        ...profile,
                        enabled: false,
                      }),
                    )
                  }
                >
                  {t("personalization.disable")}
                </Button>
              )}
              {profile.invitation_dismissed && (
                <Button
                  variant="secondary"
                  disabled={busy || trialPhase !== "idle"}
                  onClick={() =>
                    void perform(() => commands.deletePersonalization())
                  }
                >
                  {t("personalization.delete")}
                </Button>
              )}
            </div>
            {profile.invitation_dismissed && (
              <p className="text-sm text-text/70">
                {t("personalization.summary", {
                  uses:
                    profile.uses
                      .map((use) => t(`personalization.uses.${use}`))
                      .join(", ") || t("personalization.notSelected"),
                  domain: profile.domain
                    ? t(`personalization.domains.${profile.domain}`)
                    : t("personalization.notSelected"),
                })}
                {profile.domain === "other" && profile.other_domain
                  ? ` (${profile.other_domain})`
                  : ""}
              </p>
            )}
            {(pending || trialPhase !== "idle" || trial) && (
              <>
                <p className="text-sm text-text/70">
                  {t("personalization.configuredOnly")}
                </p>
                {!status?.service_ready && !localPolishing && (
                  <Button
                    variant="secondary"
                    onClick={() =>
                      window.dispatchEvent(
                        new CustomEvent("yanyu-settings-section", {
                          detail: "postprocessing",
                        }),
                      )
                    }
                  >
                    {t("personalization.continueSetup")}
                  </Button>
                )}
                {!status?.asr_ready && (
                  <p className="text-sm">{t("personalization.needsAsr")}</p>
                )}
                {(trialPhase === "idle" || trialLocalRoute !== null) && (
                  <p className="text-sm text-text/70">
                    {t(
                      (trialPhase === "idle" ? localPolishing : trialLocalRoute)
                        ? "personalization.localTrialInfo"
                        : "personalization.trialInfo",
                    )}
                  </p>
                )}
                {trialPhase === "idle" ? (
                  <Button
                    disabled={
                      !pending || !status?.active || !status?.asr_ready || busy
                    }
                    onClick={() => void startTrial()}
                  >
                    {t("personalization.record")}
                  </Button>
                ) : (
                  <div className="flex flex-wrap gap-2">
                    <p role="status">
                      {t(`personalization.trialPhases.${trialPhase}`)}
                    </p>
                    {trialPhase === "recording" && (
                      <Button onClick={() => void stopTrial()}>
                        {t("personalization.stop")}
                      </Button>
                    )}
                    <Button
                      variant="secondary"
                      onClick={() => void cancelTrial()}
                    >
                      {t("personalization.cancelTrial")}
                    </Button>
                  </div>
                )}
                {trial && (
                  <div className="space-y-3 select-text">
                    <h3 className="font-semibold">
                      {t("personalization.original")}
                    </h3>
                    <p className="whitespace-pre-wrap">{trial.original}</p>
                    <h3 className="font-semibold">
                      {t("personalization.processed")}
                    </h3>
                    <p className="whitespace-pre-wrap">{trial.processed}</p>
                    <p role="status" className="text-sm">
                      {t(
                        trial.processing_succeeded
                          ? trial.local_route
                            ? "personalization.localTrialSucceeded"
                            : "personalization.trialSucceeded"
                          : "personalization.trialFallback",
                      )}
                    </p>
                  </div>
                )}
              </>
            )}
          </>
        ) : step === "edit" ? (
          <>
            <fieldset className="space-y-2">
              <legend className="mb-2 font-semibold">
                {t("personalization.useQuestion")}
              </legend>
              {USES.map((use) => (
                <label key={use} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={draft.uses.includes(use)}
                    onChange={(event) =>
                      setDraft({
                        ...draft,
                        uses: event.target.checked
                          ? [...draft.uses, use]
                          : draft.uses.filter((value) => value !== use),
                      })
                    }
                  />
                  {t(`personalization.uses.${use}`)}
                </label>
              ))}
            </fieldset>
            <div className="space-y-2">
              <label id="personalization-domain" className="font-semibold">
                {t("personalization.domainQuestion")}
              </label>
              <Dropdown
                aria-labelledby="personalization-domain"
                selectedValue={draft.domain ?? "none"}
                options={[
                  { value: "none", label: t("personalization.notSelected") },
                  ...DOMAINS.map((domain) => ({
                    value: domain,
                    label: t(`personalization.domains.${domain}`),
                  })),
                ]}
                onSelect={(value) =>
                  setDraft({
                    ...draft,
                    domain: value === "none" ? null : (value as Domain),
                    other_domain: value === "other" ? draft.other_domain : "",
                  })
                }
              />
            </div>
            {draft.domain === "other" && (
              <label className="block space-y-2 text-sm">
                {t("personalization.otherDetail")}
                <Input
                  maxLength={160}
                  value={draft.other_domain}
                  onChange={(event) =>
                    setDraft({ ...draft, other_domain: event.target.value })
                  }
                />
              </label>
            )}
            <div className="flex gap-2">
              <Button onClick={() => setStep("review")}>
                {t("personalization.review")}
              </Button>
              <Button variant="secondary" onClick={() => setStep("card")}>
                {t("personalization.cancel")}
              </Button>
            </div>
          </>
        ) : (
          <>
            <p className="text-sm">
              {t("personalization.summary", {
                uses:
                  draft.uses
                    .map((use) => t(`personalization.uses.${use}`))
                    .join(", ") || t("personalization.notSelected"),
                domain: draft.domain
                  ? t(`personalization.domains.${draft.domain}`)
                  : t("personalization.notSelected"),
              })}
              {draft.domain === "other" && draft.other_domain
                ? ` (${draft.other_domain})`
                : ""}
            </p>
            <p className="text-sm">
              {t(
                localPolishing
                  ? "personalization.localDisclosure"
                  : "personalization.disclosure",
              )}
            </p>
            <p className="text-sm">{t("personalization.modeDisclosure")}</p>
            <div className="flex gap-2">
              <Button
                disabled={busy}
                onClick={() =>
                  void perform(
                    () =>
                      commands.savePersonalization({ ...draft, enabled: true }),
                    () => setStep("card"),
                  )
                }
              >
                {t("personalization.save")}
              </Button>
              <Button
                variant="secondary"
                disabled={busy}
                onClick={() => setStep("edit")}
              >
                {t("personalization.back")}
              </Button>
            </div>
          </>
        )}
      </div>
    </SettingsGroup>
  );
}
