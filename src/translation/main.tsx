import ReactDOM from "react-dom/client";
import TranslationPopover from "./TranslationPopover";
import { applyTheme, getStoredTheme } from "@/lib/utils/theme";
import "@/i18n";
import "@/App.css";

applyTheme(getStoredTheme());
ReactDOM.createRoot(document.getElementById("root")!).render(
  <TranslationPopover />,
);
