# Assignment 3 – CI/CD with GitHub Actions

A small Bash utility (`app/app.sh`) with a complete local CI pipeline: linting,
an automated test suite, a Docker image with smoke tests, and a GitHub Actions
workflow that runs the same three stages in order on every push and pull request.
There is no cloud deployment.

```
validate  (scripts/lint.sh)      required files, bash -n, shellcheck
   ↓
test      (tests/test.sh)        35 assertions against app.sh
   ↓
docker    (scripts/build.sh)     docker build + smoke tests
```

## Project layout

| Path | Purpose |
|------|---------|
| `app/app.sh` | The application: `system-info`, `check-host`, `check-port`, `help` |
| `scripts/lint.sh` | Static checks: required files exist, `bash -n` on every script, ShellCheck if installed |
| `scripts/build.sh` | Builds the Docker image and runs smoke tests (help, system-info, invalid command) |
| `tests/test.sh` | Test suite for `app.sh` (exit codes and output) |
| `.github/workflows/ci.yml` | GitHub Actions pipeline: `validate` → `test` → `docker` |
| `Dockerfile` | Alpine-based image, non-root user, `app.sh` as entrypoint |
| `compose.yaml` | Docker Compose service `devops-tool` for local runs |
| `.dockerignore` | Keeps `.git`, `.github`, logs, tests and editor files out of the build context |
| `grade.sh` | Official local grader supplied with the assignment (unmodified) |

## Requirements

- Bash 4+ on Linux (the scripts also run on macOS/Bash 3.2 for local development).
- `ping`, and `getent` (Linux) or another resolver, for the host checks.
- Docker Engine with the Compose plugin for `scripts/build.sh`, `compose.yaml` and
  the `docker` CI job.
- Optional: `shellcheck` (preinstalled on GitHub's Ubuntu runners; `lint.sh` skips
  it with a notice when absent), `python3` (used by two tests that open a real local
  TCP listener; those tests are skipped without it).

## Setup

```bash
git clone <your-repository-url>
cd assignment-3
chmod +x app/*.sh scripts/*.sh tests/*.sh grade.sh
```

## Usage

```bash
./app/app.sh system-info
./app/app.sh check-host example.com
./app/app.sh check-port example.com 443
./app/app.sh help
```

Examples:

```
$ ./app/app.sh check-port example.com 443 ; echo "exit $?"
Checking TCP port 443 on example.com
Resolved address:    93.184.215.14
TCP port 443:        OPEN
RESULT: OK
exit 0

$ ./app/app.sh check-port localhost 65536 ; echo "exit $?"
Error: port '65536' must be a whole number between 1 and 65535

Usage: app.sh <command> [arguments]
...
exit 2
```

### Exit codes

| Code | Meaning | Examples |
|------|---------|----------|
| 0 | Success | `help`, `system-info`, host resolved and reachable, port open |
| 1 | Operational failure | host cannot be resolved, no ping reply, TCP port closed |
| 2 | Invalid command or input | no command, unknown command, missing host/port, malformed host, port not in 1–65535, extra arguments |

Invalid input is always distinguished from network failures: `check-port localhost abc`
exits 2 before any network activity, while `check-port localhost 1` (a closed port)
exits 1.

## Linting

```bash
./scripts/lint.sh
```

Checks that all required files exist, runs `bash -n` on every script under `app/`,
`scripts/` and `tests/`, verifies executable bits, and runs ShellCheck when it is
available. Any problem makes the script exit 1, which fails the `validate` job.

## Testing

```bash
./tests/test.sh
```

The suite contains 35 assertions grouped by requirement:

1. **help** – exits 0, prints usage, lists every command and the exit codes.
2. **system-info** – exits 0 and shows hostname, kernel, uptime and memory; rejects extra arguments.
3. **invalid commands** – no command, unknown command and empty command exit 2.
4. **missing host** – `check-host` without a host, with a malformed host, or with extra arguments exits 2.
5. **valid host** – `localhost` and `127.0.0.1` exit 0 and show the resolved address; `nonexistent.invalid` exits 1.
6. **missing port** – `check-port` with no arguments or only a host exits 2.
7. **non-numeric port** – `abc`, `1.5` and `-1` exit 2.
8. **out-of-range ports** – `0`, `65536` and `99999` exit 2.
9. **real TCP behaviour** – a temporary listener on 127.0.0.1 is reported OPEN (exit 0) and a free port is reported CLOSED (exit 1).

Any failed assertion makes the script exit 1. Run the official grader with:

```bash
chmod +x grade.sh app/*.sh scripts/*.sh tests/*.sh
./grade.sh
```

## Docker

```bash
docker build -t devops-tool .
docker run --rm devops-tool help
docker run --rm devops-tool system-info
docker run --rm devops-tool check-port example.com 443
docker run --rm devops-tool invalid-command ; echo $?     # 2
```

`scripts/build.sh` performs the same steps automatically: it builds the image
(tag from `IMAGE`, default `devops-tool`) and runs smoke tests for `help`, the
default command, `system-info`, an invalid command (must exit 2), a missing command
and a bad port. Pass `--clean` to remove the image afterwards, as the CI job does.

Image notes: `alpine:3.20` base, only `bash` and `iproute2` added, `app.sh` verified
during the build, runs as the non-root user `app`, `ENTRYPOINT ["/app/app.sh"]`
with `CMD ["help"]`.

### Docker Compose

```bash
docker compose config                                   # validate
docker compose build
docker compose run --rm devops-tool system-info
docker compose run --rm devops-tool check-host 8.8.8.8
```

## GitHub Actions

`.github/workflows/ci.yml` runs on `push`, `pull_request` and manually
(`workflow_dispatch`). It defines three jobs on `ubuntu-latest`:

| Job | Depends on | What it runs |
|-----|------------|--------------|
| `validate` | – | `./scripts/lint.sh` |
| `test` | `needs: validate` | `./tests/test.sh` |
| `docker` | `needs: test` | `docker compose config`, then `./scripts/build.sh --clean` |

Because of the `needs:` chain, a lint failure stops the pipeline before the tests
run, and a test failure prevents the Docker image from being built.

## CI failure demonstration

See the section at the end of this file; it is filled in with links to the actual
workflow runs once the demonstration has been performed.

## Git workflow

Development happened on feature branches (`feature/app`, `feature/quality-checks`,
`feature/docker`, `feature/ci`) merged into `main` with merge commits, plus the
`ci/failure-demo` branch used for the demonstration. `git log --oneline --graph --all`
shows the history. Push all branches with `git push --all`.

## Assumptions

- The pipeline targets GitHub-hosted Ubuntu runners, which provide Docker, Docker
  Compose, ShellCheck and Python 3 out of the box.
- ICMP may be filtered in some environments; `check-host` then exits 1. The tests use
  `localhost`, where ping is always available.
- Name lookups are limited to 5 seconds so a broken resolver cannot hang the tool.

## Troubleshooting

- **`Permission denied`** – run `chmod +x app/*.sh scripts/*.sh tests/*.sh`.
- **`validate` job fails** – open the job log; `lint.sh` names the missing file or the
  script with the syntax/ShellCheck problem.
- **`docker` job fails but the tests passed** – run `./scripts/build.sh` locally; the
  smoke test output shows which command misbehaved inside the container.
- **Local tests skip the TCP listener checks** – install `python3`.
- **`check-host` exits 1 for a live host** – ICMP is blocked; use `check-port` with a
  known port instead.
