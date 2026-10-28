import React from "react";

interface SettingsGroupProps {
  title?: string;
  description?: string;
  variant?: "default" | "card";
  icon?: React.ReactNode;
  accessory?: React.ReactNode;
  children: React.ReactNode;
}

export const SettingsGroup: React.FC<SettingsGroupProps> = ({
  title,
  description,
  variant = "default",
  icon,
  accessory,
  children,
}) => {
  if (variant === "card") {
    return (
      <section className="settings-card dictionary-panel">
        <div className="dictionary-intro">
          {icon && (
            <span className="dictionary-icon" aria-hidden="true">
              {icon}
            </span>
          )}
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="text-lg font-semibold">{title}</h2>
            {accessory}
          </div>
          {description && (
            <p className="dictionary-description">{description}</p>
          )}
        </div>
        <div className="settings-panel-body divide-y divide-mid-gray/15">
          {children}
        </div>
      </section>
    );
  }
  return (
    <section className="settings-group space-y-3">
      {title && (
        <div className="px-4">
          <h2 className="uppercase leading-4">{title}</h2>
          {description && (
            <p className="text-xs text-mid-gray mt-1">{description}</p>
          )}
        </div>
      )}
      <div className="settings-card border overflow-visible">
        <div className="divide-y divide-mid-gray/20">{children}</div>
      </div>
    </section>
  );
};
