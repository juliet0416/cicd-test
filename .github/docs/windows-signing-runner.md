# Pro Windows signing on Mac Studio

Pro builds an unsigned MSI on a GitHub-hosted Windows runner. The reusable
`pro-windows-installer.yml` workflow then signs the MSI on the native macOS
runner, verifies it on Windows, wraps it with the locked product source's Inno
Setup script, signs the EXE on macOS, and verifies the EXE on Windows.

Files travel as GitHub Actions artifacts. Signed artifact IDs are passed to the
Windows verification jobs. No SSH connection or inbound port is used by this
pipeline. Every signing job uses a new temporary directory and removes it when
finished. Run IDs separate artifacts; overwrite allows an explicit job rerun to
replace its own stage output.

## Host setup

- Register a native macOS ARM64 runner in this packaging repository, with the
  custom label `macstudio-signing`. Keep one signing runner instance so hardware
  certificate operations execute serially.
- Run the runner service as the macOS account that already has access to the
  hardware token and working signing script.
- Set the repository variable `WINDOWS_SIGN_SCRIPT` to the existing local script
  path. The script must accept `--alg SHA-1 <file>` and `--alg SHA-256 <file>` and
  return a nonzero exit code on failure. Certificate credentials stay on the host.
- Configure the runner's outbound HTTPS proxy if direct GitHub access is not
  available. Verify access to GitHub APIs and workflow artifact storage, not just
  the GitHub website.
- Install and start the runner's user service using its generated `svc.sh`.

The signing runner does not check out repository or product code and receives no
inherited repository secrets. Its jobs accept only manual dispatch or push
events in this repository. Do not enable signing jobs on pull request events.
Because the packaging repository is public, require approval for all external
contributors' workflows, and never approve an untrusted workflow for this host.
Runner labels are routing labels, not an authorization boundary.

## Trial

`pro-signing-trial.yml` runs on the trial branch. It creates an unsigned test MSI,
executes the same MSI/sign/wrap/EXE/sign/verify chain as Pro, and retains the
verified EXE as an artifact. It neither installs the MSI nor publishes packages,
sends release notifications, or changes update pointers.

For a complete Pro build without publication, set `publish_release=false` on
`pro.yml`. This also suppresses native-package uploads and release notifications.
Production dispatches retain `publish_release=true`. Promotion waits for both the
platform build matrix and the verified Windows installer workflow.

Local retains its existing signing flow until separately migrated.
