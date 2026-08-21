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

**Bucket PUT dispatch** — `dispatch_bucket_put/2` in `router.ex` routes
`PUT /:bucket?<subresource>` to 501 instead of misreading it as CreateBucket.
See "PUT subresource routing" below; it corrects the status code but does not
change any test outcome.

## Verified

- `mix test` — 112 tests, 0 failures (on the updated deps).
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

**Implement bucket versioning**, starting with `PUT /:bucket?versioning` and
the `VersionId` plumbing behind it.

This is now the only way to move the number. See "PUT subresource routing"
below for why the routing fix alone changed nothing: those tests fail in
*setup*, and setup only succeeds if versioning genuinely works. The 501 they
get now is honest, but it is still a failure.

Scope, roughly in dependency order:

1. `PUT /:bucket?versioning` stores Enabled/Suspended per bucket, and
   `GET /:bucket?versioning` reflects it back (currently a static stub).
2. Object writes to a versioned bucket keep prior versions and return
   `x-amz-version-id`; this is the storage-layer change and the real work,
   since objects are currently plain files at their key path.
3. `GET`/`HEAD`/`DELETE` accept `?versionId=`, and DELETE without one inserts
   a delete marker.
4. `ListObjectVersions` reports real versions instead of today's single
   `null` entry per key.

Steps 1 and 4 are cheap; step 2 is a storage redesign and the point at which
this stops being a small change. Worth deciding whether FakeS3 wants versioning
at all before starting — "no versioning" is a legitimate, documented position
for a dev/test fake, and the alternative is to accept that this tail of the
suite stays red.

The rest of the failure tail is separate feature gaps: `KeyError`s for `ETag`
(14), `ChecksumAlgorithm` (14), `PartsCount` (6), plus 6 `InvalidArgument` and
4 `NoSuchUpload`.

## PUT subresource routing — fixed, and it moved nothing

**The fix is correct and the totals did not budge.** Both facts matter.

The router treated every `PUT /:bucket` as CreateBucket, so `?versioning`,
`?acl`, `?tagging` etc. returned `409 BucketAlreadyOwnedByYou` against a bucket
that already existed. `dispatch_bucket_put/2` now checks for a known bucket
subresource first and returns 501; unknown query parameters (`?x-id=...`) still
fall through to CreateBucket, so plain creation cannot break.

What it bought, measured over the full suite:

| | before | after |
|---|---|---|
| `BucketAlreadyOwnedByYou` | 396 | 3 |
| `NotImplemented` | 14 | 408 |
| passed / failed / skipped | 199 / 545 / 94 | **199 / 545 / 94** |

The passing set is byte-identical — verified by diffing the `PASSED` lists from
a run on each side of the change. Zero regressions, zero new passes.

So the earlier framing of this as "396 of the 545 failures" was misleading: it
was the top *error code*, not 396 fixable tests. Those tests call
`PutBucketVersioning` in setup and then assert on versioned behaviour; changing
409 to 501 makes the failure honest without making the test pass. Only real
versioning does that.

Kept because a wrong status code is a real bug — a client cannot distinguish
"bucket name taken" from "operation unsupported" — and because it removes 396
misleading errors from the output. Tests in `test/listing_test.exs`
("bucket PUT dispatch"), covering 501 for `?versioning`/`?acl`, 404 on a
missing bucket, 409 still returned for a genuine bare-PUT conflict, and
fall-through for unknown parameters.

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
