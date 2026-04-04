import React from "react";
import { createRoot } from "react-dom/client";
import { I18nProvider } from "./i18n";
import { App } from "./App";

const root = createRoot(document.getElementById("root")!);
root.render(
  <I18nProvider>
    <App />
  </I18nProvider>,
);
