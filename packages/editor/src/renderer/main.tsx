import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { I18nProvider } from "./i18n";
import { App } from "./App";
import { PopoutApp } from "./PopoutApp";
import { Launcher } from "./Launcher";
import { loader } from "@monaco-editor/react";
import * as monaco from "monaco-editor";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import { engine } from "./engine-client";
import { getAppMode } from "./citron-api";

// Configure Monaco workers for Vite (must be before loader.config)
self.MonacoEnvironment = {
  getWorker() {
    return new editorWorker();
  },
};

// Configure Monaco to use local bundle instead of CDN (blocked by CSP)
loader.config({ monaco });

const params = new URLSearchParams(window.location.search);
const popoutParam = params.get("popout");
const isPopout = !!popoutParam;
const popoutPanels = popoutParam ? popoutParam.split(",").map(decodeURIComponent) : [];

function AppRoot() {
  const [mode, setMode] = useState<"loading" | "launcher" | "editor">("loading");

  useEffect(() => {
    // Ask main process what mode we're in
    getAppMode().then((appMode) => {
      setMode(appMode as "loading" | "launcher" | "editor");
    });

    // When engine connects (from launcher → project open, or from HMR reload),
    // switch to editor mode.
    const cleanupConnected = engine.onConnected(() => {
      setMode("editor");
    });

    return () => {
      cleanupConnected();
    };
  }, []);

  if (mode === "loading") {
    return (
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", height: "100vh", background: "#1e1e2e" }}>
        <div style={{ width: 24, height: 24, border: "3px solid #45475a", borderTop: "3px solid #89b4fa", borderRadius: "50%", animation: "spin 1s linear infinite" }} />
      </div>
    );
  }

  if (mode === "launcher") {
    return <Launcher onProjectOpened={() => setMode("editor")} />;
  }

  return <App />;
}

const root = createRoot(document.getElementById("root")!);
root.render(
  <I18nProvider>
    {isPopout ? <PopoutApp panels={popoutPanels} /> : <AppRoot />}
  </I18nProvider>,
);
