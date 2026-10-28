import React, { useId } from "react";

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
  const titleId = useId();
  if (variant === "card") {
    return (
      <section
        aria-labelledby={titleId}
        className="settings-card grid overflow-hidden border min-[901px]:grid-cols-[minmax(240px,0.9fr)_minmax(0,1.4fr)]"
      >
        <div className="flex flex-col items-start justify-center border-b border-(--settings-border) bg-linear-145 from-(--workspace-accent-soft)/88 to-(--workspace-accent-soft)/52 p-[22px] min-[901px]:border-e min-[901px]:border-b-0 min-[901px]:p-7">
          {icon && (
            <span
              className="mb-3 grid size-11 place-items-center rounded-xl border border-(--workspace-accent)/18 bg-(--workspace-card)/72 text-(--workspace-accent) min-[901px]:mb-[18px]"
              aria-hidden="true"
            >
              {icon}
            </span>
          )}
          <div className="flex flex-wrap items-center gap-2">
            <h2
              id={titleId}
              className="text-[17px] font-semibold tracking-[-0.02em]"
            >
              {title}
            </h2>
            {accessory}
          </div>
          {description && (
            <p className="mt-2 text-[13px] leading-[1.65] text-(--workspace-muted)">
              {description}
            </p>
          )}
        </div>
        <div className="flex min-w-0 flex-col justify-center divide-y divide-mid-gray/15 px-[22px] py-2 min-[901px]:px-7">
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
