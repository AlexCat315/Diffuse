// @bun
// PluginSDK/src/index.ts
function capability(input, run, metadata = {}) {
  return { input, run, ...metadata };
}
function definePlugin(plugin) {
  return plugin;
}

// Editor/Plugins/Languages/src/index.ts
var src_default = definePlugin({ capabilities: {
  format: capability({ record: { text: "string" } }, ({ text }) => {
    const lines = text.replace(/\r\n?/g, `
`).split(`
`).map((line) => line.replace(/[ \t]+$/, ""));
    return lines.join(`
`).replace(/\n{3,}/g, `

`).replace(/^\n+|\n+$/g, "").replace(/(.+)$/s, `$1
`);
  })
} });
export {
  src_default as default
};
