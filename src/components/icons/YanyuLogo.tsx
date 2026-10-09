import { useTranslation } from "react-i18next";

const YanyuLogo = ({
  width,
  height,
  className,
}: {
  width?: number;
  height?: number;
  className?: string;
}) => {
  const { t } = useTranslation();
  return (
    <div
      style={{ width, height }}
      className={`flex items-center justify-center gap-2 ${className ?? ""}`}
    >
      <img src="/yanyu.svg" alt="" className="w-9 h-9 shrink-0" />
      <div className="flex flex-col leading-none">
        <span className="text-2xl font-semibold text-text">
          {t("app.name")}
        </span>
        <span className="text-xs tracking-widest text-text/70 mt-1">
          {t("app.wordmark")}
        </span>
      </div>
    </div>
  );
};

export default YanyuLogo;
