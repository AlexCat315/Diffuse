# AGENTS.md

Make effective use of new Swift 6 features. For instance, Swift 6 introduces changes via the SE-0409 proposal, allowing access level modifiers—such as `private import` and `internal import`—to be applied to `import` declarations.
This implies the following:
Default behavior: If no modifier is specified, the implicit access level for an import remains `public`, meaning the imported module can be referenced throughout the entire module (target). 
Restricting import scope: You can use `private import SomeModule`, which limits the use of symbols imported from `SomeModule` to that specific source file, preventing them from being referenced by other files within the same target. This achieves the "file-level import scoping" you mentioned.

I will not allow Python to pollute my project!

Avoid unnecessary supporting text, descriptive copy, and redundant UI microcopy.

Please use the `guava cli` command to run the program; do not use the `swift` command.

A changelog must be written for every new version release.