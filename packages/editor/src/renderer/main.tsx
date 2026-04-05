import React from "react";
import { createRoot } from "react-dom/client";
import { I18nProvider } from "./i18n";
import { App } from "./App";
import { PopoutApp } from "./PopoutApp";

const params = new URLSearchParams(window.location.search);
const popoutParam = params.get("popout");
const isPopout = !!popoutParam;
const popoutPanels = popoutParam ? popoutParam.split(",").map(decodeURIComponent) : [];

const root = createRoot(document.getElementById("root")!);
root.render(
  <I18nProvider>
    {isPopout ? <PopoutApp panels={popoutPanels} /> : <App />}
  </I18nProvider>,
);
