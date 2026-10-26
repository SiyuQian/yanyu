import React from "react";

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?:
    | "primary"
    | "primary-soft"
    | "secondary"
    | "warning"
    | "danger"
    | "danger-ghost"
    | "ghost";
  size?: "sm" | "md" | "lg";
}

export const Button: React.FC<ButtonProps> = ({
  children,
  className = "",
  variant = "primary",
  size = "md",
  ...props
}) => {
  const baseClasses =
    "app-button inline-flex items-center justify-center gap-2 border font-semibold leading-5 disabled:opacity-45 disabled:cursor-not-allowed cursor-pointer";

  const sizeClasses = {
    sm: "min-h-8 px-3 py-1 text-xs",
    md: "min-h-[38px] px-4 py-2 text-sm",
    lg: "min-h-11 px-5 py-2.5 text-base",
  };

  return (
    <button
      data-variant={variant}
      className={`${baseClasses} ${sizeClasses[size]} ${className}`}
      {...props}
    >
      {children}
    </button>
  );
};
