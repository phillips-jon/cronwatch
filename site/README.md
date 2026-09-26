# cronwatch.dev

A static site: `src/landing.html` plus `docs/*.md`, built by `build.mjs` into `dist/`. The landing page opens with a paragraph rather than a slogan, then runs as labelled rows: a strip of one day's recorded runs drawn as SVG from `src/demo/runs.json`, the alerts, the code, the MCP reply and the dashboard board, all rendered from the captures in `src/demo`. Fonts are self hosted from `src/assets/fonts`.

```bash
npm run dev --workspace site      # build, watch, serve on http://localhost:4321
npm run build --workspace site    # build once
```

The terminals on the landing page quote real library output (the console alerts and an MCP reply), captured from a seeded demo rather than typed by hand. To refresh those captures after a change to the SDK or the MCP server, build both packages and run:

```bash
node site/scripts/demo.mjs --capture    # writes src/demo/alerts.txt, mcp.json, jobs.json
node site/scripts/demo.mjs              # or serve the live demo dashboard on http://localhost:4399/cronwatch/
```

The captured files are committed so a deploy never needs the packages built. Type is Soleil and Auger Mono from the Adobe Fonts kit `gie6nes`; cronwatch.dev must be on that kit's domain list or the fallback fonts show. The nginx CSP allows use.typekit.net and nothing else external.
