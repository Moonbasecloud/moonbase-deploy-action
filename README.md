# Deploy to moonbase

**AI built your app. moonbase runs everything else.**

Hosting, database, domains, analytics, rollbacks, team access — all in one platform, all run by your AI agent.

### → [moonbase.cloud](https://moonbase.cloud/?utm_source=github&utm_medium=moonbase-deploy-action&utm_campaign=gh-launch)

This is a GitHub Action that packages your repository and deploys it to a moonbase project. Every push to your main branch can ship a new version, and the job passes only when moonbase confirms the deploy is live.

It uses the documented moonbase deploy API with your own API key, kept as a repository secret.


## Quick start

1. **Create an API key with the deploy scope.** In moonbase, open **API Keys** in the sidebar and create a new key with deploy scope. It starts with `mb_live_`.
2. **Save it as a secret.** In your GitHub repository: **Settings → Secrets and variables → Actions → New repository secret**. Name `MOONBASE_API_KEY`, value the key.
3. **Find the project id.** It is in the project's link: `https://app.moonbase.cloud/missions/<id>`. Save it as the secret `MOONBASE_MISSION_ID`.
4. **Add the workflow.** Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to moonbase

on:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: moonbase-deploy
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 25
    steps:
      - uses: actions/checkout@v4
      - name: Deploy to moonbase
        uses: Moonbasecloud/moonbase-deploy-action@v1
        with:
          api-key: ${{ secrets.MOONBASE_API_KEY }}
          mission-id: ${{ secrets.MOONBASE_MISSION_ID }}
```

5. **Push to `main`.** The job log shows the live address when the deploy is done.

The same file, with comments, is in [`examples/deploy.yml`](examples/deploy.yml).

No project yet? Create one in moonbase first (upload once with the **+ New mission** button, or ask your AI agent), or see [First deploy](#first-deploy) below.

## Inputs

| Input | Required | Default | What it is |
|---|---|---|---|
| `api-key` | yes | | Your moonbase API key. Pass it from a secret. |
| `mission-id` | one of the two | | The id of an existing project. Ships a new version to it. |
| `name` | one of the two | | The address of a new project to create. For a first deploy only. |
| `display-name` | no | | A display name for the new project. Only with `name`. |
| `working-directory` | no | `.` | The folder to deploy, relative to the repository root. Its `package.json` or `index.html` must be at its top. |
| `allow-build-output` | no | `false` | `true` ships a committed static build folder (`dist/`, `build/`, `out/`). |

## Outputs

| Output | What it is |
|---|---|
| `url` | The live address of the project. |
| `project-id` | The project id. Use it as `mission-id` next time. |
| `outcome` | `live`, `not-ready`, `assets-not-loading`, `failed` or `unknown`. |

```yaml
      - name: Deploy to moonbase
        id: moonbase
        uses: Moonbasecloud/moonbase-deploy-action@v1
        with:
          api-key: ${{ secrets.MOONBASE_API_KEY }}
          mission-id: ${{ secrets.MOONBASE_MISSION_ID }}
      - name: Show the live address
        env:
          LIVE_URL: ${{ steps.moonbase.outputs.url }}
        run: echo "Live at $LIVE_URL"
```

## What gets uploaded

The action packages the files **tracked by git** in the folder you deploy. moonbase installs dependencies and builds the project itself, so you do not build in the workflow.

These never ship, even when they are committed. The action stops before any upload and lists them:

- `.env` files (`.env.example` is allowed), `node_modules`, `.git`
- database files, logs and uploaded files
- build output (`.next/`, `dist/`, `build/`, `out/`), unless you set `allow-build-output: true`

Secrets your app needs do not belong in the repository. Set them in moonbase, under the project's **Environment Variables**. See [Environment Variables](https://moonbase.cloud/docs/environment-variables?utm_source=github&utm_medium=moonbase-deploy-action&utm_campaign=gh-launch).

## How the job ends

| Result | Job | What to do |
|---|---|---|
| Deployed and live | passes | Nothing. |
| Deployed, the app reports it is not ready | fails | The upload landed. Do not re-run it. Check the project and finish its configuration. |
| Deployed, the page's files do not load | fails | Waiting does not help. Change the project and push again. |
| Build failed or the deploy was refused | fails | The log shows moonbase's explanation and a `TRK-…` reference for support. |
| Outcome unknown (the connection dropped, or the stream was cut) | fails | Check the project's status before you run the deploy again, so a deploy that landed is not uploaded twice. |

The action makes one attempt and does not retry by itself. Some refusals are safe to try again after a wait, for example a deploy that is already running on the project or a rate limit; re-run the job in that case.

## Your key stays private

- The key is masked in the log before anything else runs.
- It is sent to `curl` on standard input, never as a command-line argument.
- The raw response from moonbase is kept in a private temporary file and deleted. Only cleaned, structured fields are printed.
- Inputs are checked first. A missing or malformed key, project id or name stops the job before any upload.

Use a repository or environment secret for the key. Never write it in the workflow file.

## First deploy

To create the project from the workflow, pass `name` in place of `mission-id`:

```yaml
        with:
          api-key: ${{ secrets.MOONBASE_API_KEY }}
          name: my-app
          display-name: My App
```

After that first run, save the `project-id` output (also printed in the log) as `MOONBASE_MISSION_ID` and switch the workflow to `mission-id`. Leaving `name` in place asks moonbase for a new project on every push.

## A project in a sub-folder

```yaml
        with:
          api-key: ${{ secrets.MOONBASE_API_KEY }}
          mission-id: ${{ secrets.MOONBASE_MISSION_ID }}
          working-directory: apps/web
```

## Limits to know

- moonbase runs one build at a time per project. The `concurrency` block in the example makes a new push wait for the running deploy.
- An account can make a few deploys per 5 minutes and up to 100 per hour.
- A deploy can take several minutes. The action waits up to 20 minutes for the result.
- Your plan's project, storage and per-deploy size limits apply. See [Pricing](https://moonbase.cloud/pricing?utm_source=github&utm_medium=moonbase-deploy-action&utm_campaign=gh-launch).

## Requirements

A Linux or macOS runner with `bash`, `curl`, `jq`, `zip`, `unzip` and `git`. `ubuntu-latest` has them all. Run `actions/checkout` before this action.

## How it works

One documented call: a multipart `POST` to `https://app.moonbase.cloud/api/projects/upload/stream` with the form fields `file` and `redeployProjectId` (or `name` and `displayName`), an `Authorization: Bearer` header and a `User-Agent`. The response is a stream of events that ends with `done` or `error`.

Packaging and result reading are done by the two helper scripts moonbase ships with its skill, copied here unchanged: [`scripts/package-mission.sh`](scripts/package-mission.sh) and [`scripts/parse-deploy-result.sh`](scripts/parse-deploy-result.sh).

- [Deploying from GitHub Actions](https://moonbase.cloud/docs/github-actions-ci-cd?utm_source=github&utm_medium=moonbase-deploy-action&utm_campaign=gh-launch)
- [API Reference](https://moonbase.cloud/docs/api-reference?utm_source=github&utm_medium=moonbase-deploy-action&utm_campaign=gh-launch)

## Develop

```bash
bash test/run.sh                 # the action's tests
bash test/check-skill-drift.sh   # the helper scripts still match the Skill
```

The tests use recorded responses and a stand-in for `curl`. They need no network and no real key.

The drift check downloads the Skill's two helper scripts from the public repository [`Moonbasecloud/moonbase-skill`](https://github.com/Moonbasecloud/moonbase-skill), at the commit pinned in [`test/check-skill-drift.sh`](test/check-skill-drift.sh) (folder `moonbase/scripts/`), and fails if either differs from the copy in `scripts/`. To take a newer Skill release, copy its two scripts into `scripts/`, move the pin to that release's commit, and run the check.

CI runs the tests, `shellcheck`, `actionlint` and the drift check on every push to `main` and on every pull request: [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## License

MIT. See [LICENSE](LICENSE).
