declare module "*.svg" {
  const url: string;
  export default url;
}

declare module "*.md?raw" {
  const content: string;
  export default content;
}

declare module "*.css" {
  const content: Record<string, string>;
  export default content;
}

declare module "@icons/*" {
  const url: string;
  export default url;
}

declare module "monaco-editor/esm/vs/editor/editor.worker?worker" {
  const WorkerFactory: new () => Worker;
  export default WorkerFactory;
}
