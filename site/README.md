# cronwatch.dev

A static site: `src/landing.html`, `docs/*.md` and `pages/*.md`, built by `build.mjs` into `dist/`. The landing page opens with a paragraph rather than a slogan, then runs as labelled rows: the dashboard's last-24-hours timeline and its jobs board in a browser frame, redrawn from the captured dashboard page `src/demo/dashboard.html`, the alerts and the MCP reply, rendered from the captures in `src/demo`. The two diagrams labelled as illustrations are drawn by hand in `build.mjs`. Beside the pages, `build.mjs` also writes `prompt.txt` (copied from `src/prompt.txt`), `llms.txt`, the sitemap and the `/go/` import pages that serve `cronwatch.dev/go`.

```bash
npm run dev:site                  # from the repo root: build, watch, serve on http://localhost:4321
npm run dev:dashboard             # a dashboard of dummy jobs on http://localhost:3717/cronwatch/
npm run build --workspace site    # build once
```

The terminals on the landing page quote real library output (the console alerts and an MCP reply), captured from a seeded demo rather than typed by hand. To refresh those captures after a change to the SDK or the MCP server, build both packages and run:

```bash
TZ=UTC node site/scripts/demo.mjs --capture    # writes src/demo/alerts.txt, mcp.json, jobs.json, dashboard.html
node site/scripts/demo.mjs                     # or serve the live demo dashboard on http://localhost:4399/cronwatch/
```

The captured files are committed so a deploy never needs the packages built, and a one-off build fails if they are missing (the dev server only warns). Type is Calluna for prose and Auger Mono for machine output, both from the owner's Adobe Fonts kit. The kit and the owner's Umami analytics are the only other origins the page loads from, so the nginx CSP (`deploy/nginx.conf`) is `'self'` plus `use.typekit.net` for styles and fonts, `p.typekit.net` for styles, and `t.cronwatch.dev` for the analytics script and its reports, with no inline scripts or styles: the pages are served dark, and a stored light choice is applied by `src/theme.js`, a separate script loaded in the head before the stylesheet.
