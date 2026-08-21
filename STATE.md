# State

Last updated: 2026-08-21

## What landed

**`mise.toml`** — pins the toolchain (erlang 28.3, elixir 1.19.4-otp-28, plus
awscli/shellcheck/shfmt for `test_aws_cli.sh` and python/uv for s3-tests) and
carries the task list: `deps`, `compile`, `server`, `test`, `format`, `lint`,
`test-aws-cli`, `check`, `s3-tests-install`, `s3-tests`.

**ceph/s3-tests harness** — `[bootstrap.repos]` clones the suite to
`vendor/s3-tests` (gitignored); a `post-repos` hook runs `s3-tests-install`,
which builds the venv with uv. `s3tests.conf` at the repo root points the suite
at `127.0.0.1:4569` and is exported as `S3TEST_CONF` from `mise.toml`.

```sh
mise bootstrap      # once: clone + venv
mise run server     # separate shell
mise run s3-tests   # defaults to s3tests/functional/test_s3.py
```

**`ListObjectVersions`** — added (`router.ex`, `s3_xml.ex`) because the suite's
teardown fixture empties buckets with it; without it every test errored. FakeS3
is unversioned, so every key is reported once as latest at version `null`.
Covered by two new cases in `test/listing_test.exs`.

## Verified

- `mix test` — 105 tests, 0 failures.
- `mise bootstrap` — works from a clean tree (`rm -rf vendor` then bootstrap).
- Full `test_s3.py` run completes in ~2.5 min: **122 passed, 143 failed,
  1 skipped, 573 errors** out of 838 collected.

Note: the ExUnit suite boots a listener on `FAKES3_PORT`, so `mix test` fails
with `:eaddrinuse` while `mise run server` is up on the same port. Use
`FAKES3_PORT=4599 mix test` to run both at once.

## The 573 errors are one bug, not 573

All 573 are the same `BucketNotEmpty` on `DeleteBucket`, cascading from a single
stuck bucket. `test_bucket_create_special_key_names` creates keys
`' '  "  $  %  &  '  <  >  _  '_ '  '_ _'  __`. Teardown then can't empty that
bucket, and since each subsequent test's setup nukes *all* prefixed buckets, the
same failure re-fires for every test after it — 573 of them never run at all.

Fix that one bucket and roughly 570 tests start executing, which changes the
real pass/fail picture far more than any individual feature would.

## Recommended next action

Make special-character keys round-trip through list → delete, so
`nuke_bucket` can empty that bucket.

Likely culprits, in order of suspicion:
1. XML escaping of `&`, `<`, `>`, `"` in listing output — if keys come back
   escaped (or double-escaped), `delete_objects` sends a key that no longer
   matches what is stored.
2. The space-only key `' '` and trailing-space keys `'_ '` — check they survive
   path encoding and filesystem storage.
3. `%` in a key, given the existing `encoding-type=url` handling.

Reproduce directly:

```sh
mise run s3-tests -- s3tests/functional/test_s3.py::test_bucket_create_special_key_names
```

Then re-run the full file and expect the error count to collapse. Only after
that is the pass/fail breakdown worth reading as a compatibility signal.

## Known loose ends

- `mise run lint` fails on pre-existing issues in `test_aws_cli.sh`: 5
  shellcheck findings (SC2034 at lines 171/226, SC2015 at 318/344/363) and an
  `shfmt -i 4` diff. So `mise run check` fails out of the box. Untouched — the
  script's behavior was not in scope.
- `mix deps.get` reports a security advisory on `xml_builder`
  (EEF-CVE-2026-48590, LOW): element and attribute names are injected verbatim
  into XML output. Worth a look since this project builds S3 XML from
  user-supplied bucket and key names — and see suspicion #1 above, which may be
  the same underlying escaping gap.
- s3-tests is deliberately not wired into `mise run check`.
