import systemPromptMd from "../prompts/system.md?raw";
import { AI_TOOLS } from "../services/ai-tools";
import { engine } from "../engine-client";

/** Build the full system prompt with tool list and optional scene context. */
export function buildSystemPrompt(opts: {
  maxToolRounds?: number;
  sceneContext?: string;
}): string {
  const { maxToolRounds = 25, sceneContext } = opts;

  // Build categorized tool list
  const categories = new Map<string, string[]>();
  for (const tool of AI_TOOLS) {
    const list = categories.get(tool.category) ?? [];
    list.push(`  - ${tool.name}: ${tool.description}`);
    categories.set(tool.category, list);
  }

  let toolList = "";
  for (const [cat, items] of categories) {
    toolList += `\n### ${cat}\n${items.join("\n")}`;
  }

  const parts: string[] = [
    systemPromptMd,
    "",
    `## Tool Limit`,
    `You have a maximum of **${maxToolRounds}** tool-call rounds per message. Batch related operations when possible.`,
    "",
    `## Available Tools`,
    toolList,
  ];

  if (sceneContext) {
    parts.push("", "## Current Scene Context", sceneContext);
  }

  return parts.join("\n");
}

/** Gather runtime scene context from the engine. */
export async function gatherSceneContext(): Promise<string | undefined> {
  try {
    const hierarchy = await engine.call("scene.getHierarchy" as never, {} as never);
    if (!hierarchy) return undefined;
    return "```json\n" + JSON.stringify(hierarchy, null, 2) + "\n```";
  } catch {
    return undefined;
  }
}
