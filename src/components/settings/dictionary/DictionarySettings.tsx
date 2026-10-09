import React from "react";
import { CustomWords } from "../CustomWords";
import { SettingsGroup } from "../../ui/SettingsGroup";

export const DictionarySettings: React.FC = () => (
  <div className="max-w-3xl w-full mx-auto space-y-6">
    <SettingsGroup>
      <CustomWords descriptionMode="inline" grouped />
    </SettingsGroup>
  </div>
);
