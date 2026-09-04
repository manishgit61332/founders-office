# GitHub operating workflow

Repository: [manishgit61332/founders-office](https://github.com/manishgit61332/founders-office)

Visibility: Private

Default branch: `main`

## Normal change

1. Start from current `main`.
2. Create `codex/<short-name>` or `feature/<short-name>`.
3. Link a GitHub issue.
4. Run the repository-safety and CI scripts.
5. Push and open a pull request.
6. Merge only after `Build and verify` passes.
7. Use squash merge and delete the branch.

The cloud checks validate the privacy boundary, shared model, release Swift
package, deterministic motion, plists/manifests, generated Xcode project,
unsigned macOS and iOS Simulator builds, and website policy. A full-Xcode Mac
runner executes—not only compiles—the serial macOS UI suite and retains its
`.xcresult` on failure. A separate Linux runner starts the exact local Supabase
Postgres image selected by the pinned CLI and executes the pgTAP RLS/RPC suite.
Neither local CI service is production evidence.

## Local push gate

Run once per clone:

```bash
Scripts/install-git-hooks.sh
```

The pre-push hook runs both repository safety and CI checks. Bypass it only when diagnosing the hook itself, and record that exception in the pull request.

## Private-repository plan limitation

GitHub returned HTTP 403 when branch rules and classic branch protection were requested for this private personal-account repository. Those controls require GitHub Pro or public visibility on the current plan.

The repository remains private. It must not be made public to obtain branch protection because the bundle identifiers and product history are not ready for public release.

Until the account is upgraded:

- pull requests and squash merge are the documented policy;
- the local pre-push hook blocks known private files and failed builds;
- Actions runs on every pull request and every push to `main`;
- merge commits and rebase merges are disabled;
- merged branches are deleted automatically;
- Actions has read-only repository permissions and cannot approve pull requests.

After upgrading, enable:

- pull request required for `main`;
- `Build and verify`, `Website safety and build`, and `Execute local Supabase RLS and RPC tests` required and up to date;
- conversation resolution and linear history;
- force-push and deletion blocks;
- zero required approvals while there is only one maintainer;
- owner emergency bypass.

## Work tracking

- `Paid beta` is the release milestone.
- P0 launch gates are GitHub issues with priority, status, type, and area labels.
- Customer-facing changes go to `CHANGELOG.md`.
- Durable decisions go to `docs/decisions/`.
- Distributed build evidence goes to `docs/releases/`.
