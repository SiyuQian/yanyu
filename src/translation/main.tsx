import ReactDOM from "react-dom/client";
import TranslationPopover from "./TranslationPopover";
import { listen } from "@tauri-apps/api/event";
import {
  applyTheme,
  getStoredTheme,
  syncThemeFromSettings,
} from "@/lib/utils/theme";
import type { Theme } from "@/bindings";
import "@/i18n";
import "@/App.css";

applyTheme(getStoredTheme());
syncThemeFromSettings();
listen<Theme>("theme-changed", (event) => applyTheme(event.payload));
ReactDOM.createRoot(document.getElementById("root")!).render(
  <TranslationPopover />,
);
