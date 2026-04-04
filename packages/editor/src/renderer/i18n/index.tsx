import React, { createContext, useContext, useState, useCallback } from "react";
import { en, type TranslationKeys } from "./locales/en";
import { zhCN } from "./locales/zh-CN";

export type Locale = "en" | "zh-CN";

const localeMap: Record<Locale, TranslationKeys> = {
  en,
  "zh-CN": zhCN,
};

interface I18nContext {
  locale: Locale;
  t: TranslationKeys;
  setLocale: (locale: Locale) => void;
}

const I18nCtx = createContext<I18nContext>({
  locale: "en",
  t: en,
  setLocale: () => {},
});

function detectLocale(): Locale {
  const saved = localStorage.getItem("guava-editor-locale");
  if (saved && saved in localeMap) return saved as Locale;
  const nav = navigator.language;
  if (nav.startsWith("zh")) return "zh-CN";
  return "en";
}

export function I18nProvider({ children }: { children: React.ReactNode }) {
  const [locale, setLocaleState] = useState<Locale>(detectLocale);

  const setLocale = useCallback((l: Locale) => {
    setLocaleState(l);
    localStorage.setItem("guava-editor-locale", l);
  }, []);

  return (
    <I18nCtx.Provider value={{ locale, t: localeMap[locale], setLocale }}>
      {children}
    </I18nCtx.Provider>
  );
}

export function useI18n() {
  return useContext(I18nCtx);
}

export type { TranslationKeys };
