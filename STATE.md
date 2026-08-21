# State

Last updated: 2026-08-21 (branch `delta`)

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

**Whitespace-significant keys** — `FakeS3.XML.text/2` and `texts/2` used to
`String.trim()` element content, so a `<Key>` of `" "` parsed as `""` and `"_ "`
parsed as `"_"`. Bulk delete then deleted the wrong object (or none), and those
keys could never be removed. Text extraction now preserves whitespace;
`XML.token/2` is the explicit opt-in for values that really are tokens
(`Quiet`, `PartNumber`, `ETag`). See "Fixed cascade" below.

## Verified

- `mix test` — 107 tests, 0 failures (on the updated deps).
- `mise run check` — lint + compile + test, all green.
- `./test_aws_cli.sh` — passes against a live server, exit 0.
- `mise bootstrap` — works from a clean tree (`rm -rf vendor` then bootstrap).
- Full `test_s3.py` run, all 838 collected tests execute:

  | | passed | failed | skipped | errors |
  |---|---|---|---|---|
  | before whitespace fix | 122 | 143 | 1 | **573** |
  | after | **199** | 545 | 94 | **0** |

Note: the ExUnit suite boots a listener on `FAKES3_PORT`, so `mix test` fails
with `:eaddrinuse` while `mise run server` is up on the same port. Use
`FAKES3_PORT=4599 mix test` to run both at once.

## Fixed cascade (was: 573 errors)

All 573 errors were one `BucketNotEmpty` on `DeleteBucket`, cascading from a
single stuck bucket left by `test_bucket_create_special_key_names` (keys
`' '  "  $  %  &  '  <  >  _  '_ '  '_ _'  __`). Because each subsequent test's
setup nukes *all* prefixed buckets, that one bucket failed every test after it.

Root cause was the `String.trim()` above — the two keys that survived were
exactly the two ending in a space. Fixed in `lib/fake_s3/xml.ex`; regression
tests in `test/bulk_delete_test.exs`. Errors are now 0 and every test runs.

## Recommended next action

**PUT on a bucket ignores its subresource.** The router treats every
`PUT /:bucket` as CreateBucket, so `PUT /b?versioning`, `?acl`, `?tagging`,
`?lifecycle` etc. all return `409 BucketAlreadyOwnedByYou` on an existing
bucket. This is now the single largest cause: **396 of the 545 failures.**

Reproduce:

```sh
curl -X PUT "http://127.0.0.1:4569/b"                  # 200
curl -X PUT "http://127.0.0.1:4569/b?versioning" -d '<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>'
# => 409 BucketAlreadyOwnedByYou, should not be a CreateBucket at all
```

The fix is a routing change, mirroring the existing `dispatch_bucket_get/2`:
add a `dispatch_bucket_put/2` that checks for a subresource before falling
through to CreateBucket. **This needs a decision** on what those subresources
should then do:

- **501 NotImplemented** — honest, small, and unblocks the routing bug without
  claiming features FakeS3 lacks. Tests that merely *set up* versioning will
  still fail, but for the right reason.
- **Accept and ignore (200)** — lets many more tests proceed, but silently lies
  about state the tests later assert on, likely trading these failures for
  confusing ones.

Recommend 501 first, since it is separable from any decision about actually
implementing versioning.

After that, the remaining failure tail is genuine feature gaps: `KeyError`s for
`VersionId` (28), `ETag` (14), `ChecksumAlgorithm` (14), `PartsCount` (6), plus
14 `NotImplemented` and 6 `InvalidArgument`.

## Known loose ends

- `mix deps.get` still reports advisories, now on **cowlib 2.19.0** (a
  transitive dep of cowboy): EEF-CVE-2026-43969 (LOW, cookie header injection),
  EEF-CVE-2026-43971 and EEF-CVE-2026-43966 (MEDIUM, Link-header smuggling and
  response splitting). All three are in header encoders FakeS3 does not call
  directly, so they look like exposure rather than an active bug — but they are
  unresolved and bounded only by cowboy's own release cadence.
- s3-tests is deliberately not wired into `mise run check`.

## Resolved

- **`mise run lint` is clean and `mise run check` passes end to end.**
  `test_aws_cli.sh` had 9 shellcheck findings plus an `shfmt -i 4` diff. Two
  were real bugs, not style: `PAGE2` was fetched and never inspected, so
  "Pagination continuation works" passed unconditionally — it now asserts the
  second page actually contains keys; and `RANGE_RESULT` existed only to
  swallow stdout, replaced with an explicit redirect. The other seven were
  `A && B || C` chains converted to the `if/then/else` the file already uses
  everywhere else. Verified by running the script against a live server: all
  tests pass, exit 0, and the strengthened pagination branch is genuinely
  exercised rather than skipped.
- **`xml_builder` advisory (EEF-CVE-2026-48590) is gone** as of the dep update
  to 2.4.1. Note this was never the cause of the whitespace bug above — that
  was FakeS3's own request parsing, not xml_builder's output escaping.
