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
      <section className="settings-card rounded-xl border border-mid-gray/20 px-4 py-2 sm:px-5">
        <div className="flex flex-wrap items-center justify-between gap-2 py-3">
          <h2 className="flex items-center gap-3 text-base font-semibold">
            <span className="text-background-ui" aria-hidden="true">
              {icon}
            </span>
            {title}
          </h2>
          {accessory}
        </div>
        {description && (
          <p className="mb-2 text-sm text-text/60">{description}</p>
        )}
        <div className="divide-y divide-mid-gray/15">{children}</div>
      </section>
    );
  }
  return (
    <div className="space-y-2">
      {title && (
        <div className="px-4">
          <h2 className="text-xs font-medium text-mid-gray uppercase tracking-wide">
            {title}
          </h2>
          {description && (
            <p className="text-xs text-mid-gray mt-1">{description}</p>
          )}
        </div>
      )}
      <div className="bg-background border border-mid-gray/20 rounded-lg overflow-visible">
        <div className="divide-y divide-mid-gray/20">{children}</div>
      </div>
    </div>
  );
};
