# Deploying cronwatch.dev

The site is static: `site/dist`, built by `npm run build:site`. On the server it follows the same release pattern as the other sites on the box.

```
/var/www/cronwatch.dev-repo.git          bare clone that fetches from GitHub
/var/www/cronwatch.dev-releases/<name>/  one git worktree per release, built where it sits
/var/www/cronwatch.dev                   symlink to the live release; nginx serves its site/dist
/opt/node-cronwatch                      the Node the builds run on
```

`release-deploy` fetches, builds a new worktree beside the live one, checks that `site/dist/index.html` and the docs exist, marks the release `.release-ok`, moves the symlink in one rename, and confirms `https://cronwatch.dev/` answers 200 (switching back if not). nginx follows the symlink, so nothing restarts. The newest three releases that went live are kept; `rollback` switches to the previous one at once.

## One-time setup

As root:

1. Node for the builds: `cp -a /opt/node-v24.18.0-linux-x64 /opt/node-cronwatch` (or whichever pinned Node the other apps use).
2. The vhost: install `deploy/nginx.conf` as `/etc/nginx/sites-available/cronwatch.dev`, symlink into `sites-enabled` with only the port 80 block active, `nginx -t`, reload, then `certbot certonly --webroot -w /var/www/certbot -d cronwatch.dev -d www.cronwatch.dev`, enable the 443 blocks, `nginx -t`, reload.
3. The deploy key: generate a keypair for GitHub Actions and add the public half to `/home/joncphillips/.ssh/authorized_keys` as
   `command="/usr/bin/flock -w 3600 /home/joncphillips/.build.lock /var/www/cronwatch.dev/deploy/release-deploy",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 ...`

As joncphillips:

4. `git clone --bare https://github.com/phillips-jon/cronwatch.git /var/www/cronwatch.dev-repo.git` (a public repository needs no key; for a private one use a deploy key and an SSH alias).
5. `mkdir /var/www/cronwatch.dev-releases`
6. First release, without switching: check out the repo somewhere temporary and run `deploy/release-deploy --prepare`, or run the script from the bare clone's worktree. Then `ln -s /var/www/cronwatch.dev-releases/<name> /var/www/cronwatch.dev`.

On GitHub: secrets `DEPLOY_SSH_KEY` (the private half) and `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan -p 2222 cronwatch.dev`), then the repository variable `DEPLOY_ENABLED=true`. From then on every push to `main` deploys.

## Day to day

```
ssh joncpu /var/www/cronwatch.dev/deploy/release-deploy --force   # rebuild the live commit
ssh joncpu /var/www/cronwatch.dev/deploy/rollback                 # back to the previous release
```

The copy of `release-deploy` that runs is the live release's, so a push that changes the script is deployed by the previous version; run it once by hand with `--force` to exercise a new one.
