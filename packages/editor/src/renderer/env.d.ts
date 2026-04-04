declare module "*.svg" {
  const url: string;
  export default url;
}

declare module "*.css" {
  const content: Record<string, string>;
  export default content;
}

declare module "@icons/*" {
  const url: string;
  export default url;
}
