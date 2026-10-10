import React from "react";
import ReactDOM from "react-dom/client";
import CorrectionPanel from "./CorrectionPanel";
import {
  applyTheme,
  getStoredTheme,
  syncThemeFromSettings,
} from "@/lib/utils/theme";
import "@/App.css";
import "@/i18n";

applyTheme(getStoredTheme());
syncThemeFromSettings();
ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <CorrectionPanel />
  </React.StrictMode>,
);
