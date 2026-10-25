import { MeetingsPage } from "@/components/meetings/MeetingsPage";
import React from "react";
import { useTranslation } from "react-i18next";
import {
  BookA,
  ChartColumn,
  Cog,
  Cpu,
  FlaskConical,
  Info,
  Mic,
  Type,
  type LucideIcon,
} from "lucide-react";
import YanyuLogo from "./icons/YanyuLogo";
import { useSettings } from "../hooks/useSettings";
import type { AppSettings } from "@/bindings";
import {
  GeneralSettings,
  AdvancedSettings,
  HistorySettings,
  DebugSettings,
  AboutSettings,
  PostProcessingSettings,
  ModelsSettings,
  DictionarySettings,
} from "./settings";

export type SidebarSection = keyof typeof SECTIONS_CONFIG;

interface SectionConfig {
  labelKey: string;
  descriptionKey: string;
  icon: LucideIcon;
  component: React.ComponentType;
  enabled: (settings: AppSettings | null) => boolean;
  // Secondary sections render in a separate group pinned to the bottom.
  secondary?: boolean;
}

export const SECTIONS_CONFIG = {
  general: {
    labelKey: "sidebar.general",
    descriptionKey: "settings.general.pageDescription",
    icon: Mic,
    component: GeneralSettings,
    enabled: () => true,
  },
  meetings: {
    labelKey: "sidebar.meetings",
    descriptionKey: "meetings.privacy",
    icon: BookA,
    component: MeetingsPage,
    enabled: () => true,
  },
  history: {
    labelKey: "sidebar.history",
    descriptionKey: "workspace.descriptions.history",
    icon: ChartColumn,
    component: HistorySettings,
    enabled: () => true,
  },
  dictionary: {
    labelKey: "sidebar.dictionary",
    descriptionKey: "workspace.descriptions.dictionary",
    icon: BookA,
    component: DictionarySettings,
    enabled: () => true,
  },
  postprocessing: {
    labelKey: "sidebar.postProcessing",
    descriptionKey: "workspace.descriptions.postprocessing",
    icon: Type,
    component: PostProcessingSettings,
    enabled: () => true,
  },
  models: {
    labelKey: "sidebar.models",
    descriptionKey: "settings.models.description",
    icon: Cpu,
    component: ModelsSettings,
    enabled: () => true,
    secondary: true,
  },
  advanced: {
    labelKey: "sidebar.advanced",
    descriptionKey: "workspace.descriptions.advanced",
    icon: Cog,
    component: AdvancedSettings,
    enabled: () => true,
    secondary: true,
  },
  debug: {
    labelKey: "sidebar.debug",
    descriptionKey: "workspace.descriptions.debug",
    icon: FlaskConical,
    component: DebugSettings,
    enabled: (settings) => settings?.debug_mode ?? false,
    secondary: true,
  },
  about: {
    labelKey: "sidebar.about",
    descriptionKey: "workspace.descriptions.about",
    icon: Info,
    component: AboutSettings,
    enabled: () => true,
    secondary: true,
  },
} as const satisfies Record<string, SectionConfig>;

interface SidebarProps {
  activeSection: SidebarSection;
  onSectionChange: (section: SidebarSection) => void;
}

export const Sidebar: React.FC<SidebarProps> = ({
  activeSection,
  onSectionChange,
}) => {
  const { t } = useTranslation();
  const { settings } = useSettings();

  const availableSections = Object.entries(SECTIONS_CONFIG)
    .filter(([_, config]) => config.enabled(settings))
    .map(([id, config]) => ({
      id: id as SidebarSection,
      ...(config as SectionConfig),
    }));

  const renderItem = (section: (typeof availableSections)[number]) => {
    const Icon = section.icon;
    const isActive = activeSection === section.id;

    return (
      <button
        type="button"
        key={section.id}
        aria-current={isActive ? "page" : undefined}
        className={`sidebar-item flex gap-3 items-center px-3 py-2.5 w-full rounded-xl text-start cursor-pointer transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-background-ui ${
          isActive
            ? "bg-background-ui/15 text-background-ui"
            : "text-text/65 hover:bg-mid-gray/10 hover:text-text"
        }`}
        onClick={() => onSectionChange(section.id)}
      >
        <Icon width={20} height={20} strokeWidth={1.75} className="shrink-0" />
        <span
          className="text-sm font-medium truncate"
          title={t(section.labelKey)}
        >
          {t(section.labelKey)}
        </span>
        {isActive && <span className="sidebar-active-dot" aria-hidden="true" />}
      </button>
    );
  };

  return (
    <nav
      aria-label={t("app.name")}
      className="settings-sidebar flex flex-col shrink-0 h-full border-e border-mid-gray/15"
    >
      <YanyuLogo className="sidebar-brand" />
      <div className="sidebar-group flex flex-col w-full gap-1">
        <p className="sidebar-group-label">{t("workspace.primary")}</p>
        {availableSections.filter((s) => !s.secondary).map(renderItem)}
      </div>
      <div className="sidebar-group flex flex-col w-full gap-1 mt-auto pt-6">
        <p className="sidebar-group-label">{t("workspace.secondary")}</p>
        {availableSections.filter((s) => s.secondary).map(renderItem)}
      </div>
    </nav>
  );
};
