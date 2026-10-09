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
} from "lucide-react";
import YanyuLogo from "./icons/YanyuLogo";
import { useSettings } from "../hooks/useSettings";
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

interface IconProps {
  width?: number | string;
  height?: number | string;
  size?: number | string;
  className?: string;
  [key: string]: any;
}

interface SectionConfig {
  labelKey: string;
  icon: React.ComponentType<IconProps>;
  component: React.ComponentType;
  enabled: (settings: any) => boolean;
  // Secondary sections render in a separate group pinned to the bottom.
  secondary?: boolean;
}

export const SECTIONS_CONFIG = {
  general: {
    labelKey: "sidebar.general",
    icon: Mic,
    component: GeneralSettings,
    enabled: () => true,
  },
  history: {
    labelKey: "sidebar.history",
    icon: ChartColumn,
    component: HistorySettings,
    enabled: () => true,
  },
  dictionary: {
    labelKey: "sidebar.dictionary",
    icon: BookA,
    component: DictionarySettings,
    enabled: () => true,
  },
  postprocessing: {
    labelKey: "sidebar.postProcessing",
    icon: Type,
    component: PostProcessingSettings,
    enabled: (settings) => settings?.post_process_enabled ?? false,
  },
  models: {
    labelKey: "sidebar.models",
    icon: Cpu,
    component: ModelsSettings,
    enabled: () => true,
    secondary: true,
  },
  advanced: {
    labelKey: "sidebar.advanced",
    icon: Cog,
    component: AdvancedSettings,
    enabled: () => true,
    secondary: true,
  },
  debug: {
    labelKey: "sidebar.debug",
    icon: FlaskConical,
    component: DebugSettings,
    enabled: (settings) => settings?.debug_mode ?? false,
    secondary: true,
  },
  about: {
    labelKey: "sidebar.about",
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
      <div
        key={section.id}
        className={`flex gap-3 items-center px-3 py-2 w-full rounded-xl cursor-pointer transition-colors ${
          isActive ? "bg-mid-gray/15" : "hover:bg-mid-gray/10"
        }`}
        onClick={() => onSectionChange(section.id)}
      >
        <Icon width={20} height={20} strokeWidth={1.75} className="shrink-0" />
        <p
          className="text-[15px] font-medium truncate"
          title={t(section.labelKey)}
        >
          {t(section.labelKey)}
        </p>
      </div>
    );
  };

  return (
    <div className="flex flex-col w-48 h-full border-e border-mid-gray/20 px-3 pb-3">
      <YanyuLogo width={120} className="m-4 self-center" />
      <div className="flex flex-col w-full gap-1 pt-2">
        {availableSections.filter((s) => !s.secondary).map(renderItem)}
      </div>
      <div className="flex flex-col w-full gap-1 mt-auto pt-2 border-t border-mid-gray/20">
        {availableSections.filter((s) => s.secondary).map(renderItem)}
      </div>
    </div>
  );
};
