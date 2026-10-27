import { capability, definePlugin } from "@diffuse/plugin-sdk";
export default definePlugin({ capabilities: {
  format: capability({ record: { text: "string" } }, ({ text }) => {
    const lines = text.replace(/\r\n?/g, "\n").split("\n").map(line => line.replace(/[ \t]+$/, ""));
    return lines.join("\n").replace(/\n{3,}/g, "\n\n").replace(/^\n+|\n+$/g, "").replace(/(.+)$/s, "$1\n");
  })
} });
