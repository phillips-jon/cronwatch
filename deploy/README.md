# Deploying cronwatch.dev

The site is static: `site/dist`, built by `npm run build:site`. On the server it follows the same release pattern as the other sites on the box.

```
/var/www/cronwatch.dev-repo.git          bare clone that fetches from GitHub
/var/www/cronwatch.dev-releases/<name>/  one git worktree per release, built where it sits
/var/www/cronwatch.dev                   symlink to the live release; nginx serves its site/dist
/opt/node-cronwatch                      the Node the builds run on
```

`release-deploy` fetches, takes the commit it was given (the one CI passed; it must be on `main`, and one older than the live release is skipped) or else the tip of `main`, builds a new worktree beside the live one (installing only the site workspace), checks that `site/dist/index.html` carries the timeline of runs drawn from the demo captures and that the docs exist, marks the release `.release-ok`, moves the symlink in one rename, and confirms `https://cronwatch.dev/` answers 200 with exactly the `index.html` it just built (switching back if not; on a first deploy, with nothing to switch back to, it says so loudly and exits non-zero). nginx follows the symlink, so nothing restarts (the contact form service is the one exception; see [Contact form](#contact-form)). The newest three releases that went live are kept; `rollback` switches to the previous one at once.

## One-time setup

As root:

1. Node for the builds: `cp -a /opt/node-v24.18.0-linux-x64 /opt/node-cronwatch` (or whichever pinned Node the other apps use).
2. The vhost: install `deploy/nginx.conf` as `/etc/nginx/sites-available/cronwatch.dev`, symlink into `sites-enabled` with only the port 80 block active, `nginx -t`, reload, then `certbot certonly --webroot -w /var/www/certbot -d cronwatch.dev -d www.cronwatch.dev`, enable the 443 blocks, `nginx -t`, reload. The 443 blocks put `http2` on the listen line for nginx 1.24; on 1.25.1 or newer, switch to `http2 on;`.
3. The deploy key: generate a keypair for GitHub Actions and add the public half to `/home/joncphillips/.ssh/authorized_keys` as
   `restrict,command="/usr/bin/flock -w 900 /home/joncphillips/.build.lock /var/www/cronwatch.dev/deploy/release-deploy" ssh-ed25519 ...`
   (`restrict` turns off forwarding, the pty and anything OpenSSH adds later. The 900 second wait for the shared build lock leaves room for the build itself inside the workflow's 20 minute timeout.) The forced command never runs what the client asks for. The workflow sends `deploy <commit>`, which OpenSSH puts in `SSH_ORIGINAL_COMMAND`, and `release-deploy` accepts only `deploy` or `deploy` followed by a 40-character lower-case commit id, and refuses anything else.

As joncphillips:

4. The bare clone. The repository is public, so HTTPS works without a key. A bare clone has no fetch refspec, and `release-deploy` reads `refs/remotes/origin/main`, so add one and fetch once:
   ```
   git clone --bare https://github.com/phillips-jon/cronwatch.git /var/www/cronwatch.dev-repo.git
   git -C /var/www/cronwatch.dev-repo.git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
   git -C /var/www/cronwatch.dev-repo.git fetch origin
   git -C /var/www/cronwatch.dev-repo.git rev-parse refs/remotes/origin/main   # prints a commit
   ```
5. `mkdir /var/www/cronwatch.dev-releases`
6. First release, without switching: check out the repo somewhere temporary and run `deploy/release-deploy --prepare`, or run the script from the bare clone's worktree. Then `ln -s /var/www/cronwatch.dev-releases/<name> /var/www/cronwatch.dev`.

On GitHub: secrets `DEPLOY_SSH_KEY` (the private half) and `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan -p 2222 cronwatch.dev`), then the repository variable `DEPLOY_ENABLED=true`. From then on every push to `main` deploys once CI passes on it.

## Day to day

```
ssh joncpu /var/www/cronwatch.dev/deploy/release-deploy --force            # rebuild the tip of main
ssh joncpu /var/www/cronwatch.dev/deploy/release-deploy <commit>           # deploy that commit on main
ssh joncpu /var/www/cronwatch.dev/deploy/release-deploy --force <commit>   # even if it is older than the live one
ssh joncpu /var/www/cronwatch.dev/deploy/rollback                          # back to the previous release
```

The copy of `release-deploy` that runs is the live release's, so a push that changes the script is deployed by the previous version; run it once by hand with `--force` to exercise a new one.

A deploy never touches the nginx vhost, so a change to `deploy/nginx.conf` (the CSP, say) is installed by hand once the release carrying it is live:

```
sudo diff /etc/nginx/sites-available/cronwatch.dev /var/www/cronwatch.dev/deploy/nginx.conf
sudo cp /var/www/cronwatch.dev/deploy/nginx.conf /etc/nginx/sites-available/cronwatch.dev
sudo nginx -t && sudo systemctl reload nginx
```

## Contact form

The site is static except for one thing: the form on `/contact/` posts to `/contact`, which nginx hands to `deploy/contact/server.mjs` on `127.0.0.1:3790`. The service checks the form (a honeypot field, a minimum fill time, field lengths, a sane email address), sends one email to the maintainer through Amazon SES with the sender's address as Reply-To, and redirects the browser to `/contact/sent/` or `/contact/error/`. It has no dependencies, so it runs straight from the live release with the Node the builds use. nginx limits it to 5 posts a minute per address (burst 3), 20 a minute from everyone together (burst 10) and 16 KB a post, and sends the error page when the service is down or a limit is hit. The service itself sends at most 10 messages an hour per IPv4 address or IPv6 /64 (a host handed a whole /64 cannot take a new address per post), and 30 an hour and 100 a day in all, so a flood cannot use up the SES quota; past a limit it logs `rate-limited` or `over-cap` and sends the error page (`LIMITS` in `server.mjs`). A sender's name is put on one line, so it cannot add lines that pass for the Email or IP lines. The service logs one line per post to the journal: time, outcome, reason and IP address, never the message, the sender's details or a credential.

Its credentials live only in an env file on the server, never in the repository. To set it up:

1. **SES.** The sender identity (the domain `joncphillips.com`) must be verified in SES in `us-east-1`. While the account is in the SES sandbox it can only send to verified identities; `jon@joncphillips.com` is on the verified domain, so that works either way.

2. **An IAM user that can only send as that address.** Save this as `cronwatch-contact-policy.json`, with your account ID in place of `<account-id>`:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "ses:SendEmail",
         "Resource": "arn:aws:ses:us-east-1:<account-id>:identity/joncphillips.com",
         "Condition": { "StringEquals": { "ses:FromAddress": "contact@joncphillips.com" } }
       }
     ]
   }
   ```
   Then, with the AWS CLI signed in as an administrator:
   ```
   aws iam create-user --user-name cronwatch-contact
   aws iam put-user-policy --user-name cronwatch-contact --policy-name ses-send-contact --policy-document file://cronwatch-contact-policy.json
   aws iam create-access-key --user-name cronwatch-contact
   ```
   The last command prints `AccessKeyId` and `SecretAccessKey` once. Put them straight into the env file below and nowhere else.

3. **The env file**, as joncphillips on the server:
   ```
   mkdir -p ~/.config
   install -m 600 /dev/null ~/.config/cronwatch-contact.env
   nano ~/.config/cronwatch-contact.env
   ```
   with these lines (placeholders shown; paste the real values in the editor, not on a command line, so they stay out of shell history):
   ```
   AWS_ACCESS_KEY_ID=<access key id>
   AWS_SECRET_ACCESS_KEY=<secret access key>
   AWS_REGION=us-east-1
   CONTACT_FROM=CronWatch <contact@joncphillips.com>
   CONTACT_TO=jon@joncphillips.com
   ```
   Check it with `stat -c '%a %U' ~/.config/cronwatch-contact.env`, which should print `600 joncphillips`. systemd reads the file as root before it starts the service, so nothing else needs to read it.

4. **The service.** Deploy a release that contains `deploy/contact` first (push to `main`), then as root:
   ```
   sudo cp /var/www/cronwatch.dev/deploy/contact/cronwatch-contact.service /etc/systemd/system/cronwatch-contact.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now cronwatch-contact
   systemctl status cronwatch-contact --no-pager
   journalctl -u cronwatch-contact -n 20 --no-pager
   ```
   The journal should say `listening on 127.0.0.1:3790`. If a variable is missing, the service names it and exits (and systemd keeps retrying every 5 seconds until it is fixed).

5. **nginx.** The vhost in `deploy/nginx.conf` now has a `limit_req_zone` line at the top (the file is included inside the `http` block, where that directive belongs) and a `location = /contact`. Compare, install and reload:
   ```
   sudo diff /etc/nginx/sites-available/cronwatch.dev /var/www/cronwatch.dev/deploy/nginx.conf
   sudo cp /var/www/cronwatch.dev/deploy/nginx.conf /etc/nginx/sites-available/cronwatch.dev
   sudo nginx -t && sudo systemctl reload nginx
   ```

6. **Test it.**
   ```
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://cronwatch.dev/contact
   # 301 https://cronwatch.dev/contact/
   curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --data-urlencode 'name=Deploy test' --data-urlencode 'email=jon@joncphillips.com' --data-urlencode 'message=Testing the contact form.' https://cronwatch.dev/contact
   # 303 https://cronwatch.dev/contact/sent/, and the email arrives
   journalctl -u cronwatch-contact -n 5 --no-pager
   # {"time":"...","outcome":"sent","ip":"..."}
   ```
   Then send one through the form in a browser. A `"failed"` line names the SES error (`ses-403-AccessDenied`, say, for a policy that does not match the From address).

**After a deploy.** The service keeps running the code it started with, and `release-deploy` runs without sudo, so it does not restart it. When a deploy changes `deploy/contact/`, `release-deploy` prints a reminder; then run `sudo systemctl restart cronwatch-contact`. A restart starts the live release's copy, because the unit's path goes through the `/var/www/cronwatch.dev` symlink.

**Rotating the key.** `aws iam create-access-key --user-name cronwatch-contact`, put the new pair in the env file, `sudo systemctl restart cronwatch-contact`, send a test, then `aws iam delete-access-key --user-name cronwatch-contact --access-key-id <old access key id>`.

**Tests.** `npm run test:contact` (part of `npm test` and `npm run check`) runs the service against a fake SES on 127.0.0.1. `CONTACT_SES_URL` exists only for that, and the service refuses it unless it points at 127.0.0.1 or localhost.
