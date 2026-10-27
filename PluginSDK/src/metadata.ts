import ts from "typescript";
import type { InputType } from "./index.ts";

/** Evaluate literal metadata only. Building an AI-authored plugin must not import its executable module. */
export function metadata(source: string, filename: string) {
  const file = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const constants = new Map<string, ts.Expression>();
  for (const statement of file.statements) if (ts.isVariableStatement(statement)) {
    for (const declaration of statement.declarationList.declarations) if (ts.isIdentifier(declaration.name) && declaration.initializer) constants.set(declaration.name.text, declaration.initializer);
  }
  function object(node: ts.Expression): ts.ObjectLiteralExpression {
    if (ts.isAsExpression(node) || ts.isSatisfiesExpression(node) || ts.isParenthesizedExpression(node)) return object(node.expression);
    if (ts.isIdentifier(node) && constants.has(node.text)) return object(constants.get(node.text)!);
    if (!ts.isObjectLiteralExpression(node)) throw new Error("Plugin metadata must use object literals");
    return node;
  }
  function name(node: ts.PropertyName): string {
    if (ts.isIdentifier(node) || ts.isStringLiteral(node) || ts.isNumericLiteral(node)) return node.text;
    throw new Error("Computed metadata keys are unsupported");
  }
  function property(node: ts.ObjectLiteralExpression, key: string): ts.Expression | undefined {
    const match = node.properties.find(value => value.name && name(value.name) === key);
    return match && ts.isPropertyAssignment(match) ? match.initializer : undefined;
  }
  function literal(node: ts.Expression, seen = new Set<string>(), depth = 0): any {
    if (depth > 24) throw new Error("Metadata is too deeply nested");
    if (ts.isAsExpression(node) || ts.isSatisfiesExpression(node) || ts.isParenthesizedExpression(node)) return literal(node.expression, seen, depth + 1);
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text;
    if (ts.isNumericLiteral(node)) return Number(node.text);
    if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
    if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
    if (ts.isArrayLiteralExpression(node)) return node.elements.map(value => literal(value as ts.Expression, seen, depth + 1));
    if (ts.isIdentifier(node) && constants.has(node.text) && !seen.has(node.text)) return literal(constants.get(node.text)!, new Set([...seen, node.text]), depth + 1);
    if (ts.isObjectLiteralExpression(node)) {
      const value: Record<string, unknown> = Object.create(null);
      for (const member of node.properties) {
        if (!ts.isPropertyAssignment(member)) throw new Error("Metadata cannot contain spreads, methods or accessors");
        const key = name(member.name);
        if (Object.hasOwn(value, key)) throw new Error("Duplicate metadata key");
        value[key] = literal(member.initializer, seen, depth + 1);
      }
      return value;
    }
    throw new Error("Capability input and metadata must be static literals or literal constants");
  }
  const exported = file.statements.find(ts.isExportAssignment);
  if (!exported || !ts.isCallExpression(exported.expression) || exported.expression.arguments.length !== 1) throw new Error("Default export must be definePlugin({...})");
  const definition = object(exported.expression.arguments[0]);
  const capabilities = property(definition, "capabilities"); if (!capabilities) throw new Error("Missing capabilities");
  const entries = object(capabilities).properties.map(member => {
    if (!ts.isPropertyAssignment(member) || !ts.isCallExpression(member.initializer)) throw new Error("Capabilities must use capability(input, run, metadata?)");
    const id = name(member.name), call = member.initializer;
    if (!/^[a-z][a-z0-9-]{0,63}$/.test(id) || call.arguments.length < 2) throw new Error(`Invalid capability ${id}`);
    const input: InputType = literal(call.arguments[0]);
    const info = call.arguments[2] ? literal(call.arguments[2]) : {};
    return { name: id, input, title: String(info.title ?? id), description: String(info.description ?? "") };
  });
  if (entries.length > 64 || new Set(entries.map(value => value.name)).size !== entries.length) throw new Error("Too many or duplicate capabilities");
  return { version: 1, entries };
}
