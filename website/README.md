# Guava Engine Website

Vue 3 + TypeScript website, documentation, release download, and community portal for Guava Engine.

```bash
npm install
npm run dev
```

## Checks

```bash
npm run validate:content
npm run typecheck
npm run lint
npm run test
npm run build
```

`npm run sync:github` refreshes the bundled public fallback snapshot. Runtime requests use the unauthenticated public GitHub API and never expose a token.

Set `VITE_SITE_URL` when the static site receives a public origin so canonical, alternate-language, and social-preview URLs use that origin.
