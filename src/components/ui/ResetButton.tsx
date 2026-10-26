import React from "react";
import ResetIcon from "../icons/ResetIcon";

interface ResetButtonProps {
  onClick: () => void;
  disabled?: boolean;
  className?: string;
  ariaLabel?: string;
  children?: React.ReactNode;
}

export const ResetButton: React.FC<ResetButtonProps> = React.memo(
  ({ onClick, disabled = false, className = "", ariaLabel, children }) => (
    <button
      type="button"
      aria-label={ariaLabel}
      className={`reset-button icon-action border border-transparent ${
        disabled
          ? "opacity-45 text-text/40"
          : "text-text/80 hover:border-background-ui/30"
      } ${className}`}
      onClick={onClick}
      disabled={disabled}
    >
      {children ?? <ResetIcon />}
    </button>
  ),
);
