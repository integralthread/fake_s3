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

- `mix test` — 156 tests, 0 failures (on the updated deps).
- `mise run check` — lint + compile + test, all green.
- `./test_aws_cli.sh` — passes against a live server, exit 0.
- `mise bootstrap` — works from a clean tree (`rm -rf vendor` then bootstrap).
- Full `test_s3.py` run, all 838 collected tests execute:

  | | passed | failed | skipped | errors |
  |---|---|---|---|---|
  | before whitespace fix | 122 | 143 | 1 | **573** |
  | after whitespace fix | 199 | 545 | 94 | **0** |
  | after versioning | 217 | 527 | 94 | **0** |
  | after POST object | **249** | 495 | 94 | **0** |

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

POST object is done (below). What remains, largest first:

| area | failures | note |
|---|---|---|
| SSE / encryption (`test_copy_enc`, `test_copy_part_enc`) | ~68 | largest single block; SSE-C/SSE-KMS headers |
| object lock | 29 | retention and legal hold |
| bucket logging | 14 | Ceph extension, little value outside Ceph |
| bucket/object ACL enforcement | ~12 | currently a static stub |
| POST leftovers | 8 | 4 need signature checking, rest are tags/SSE/checksum |

**Two paths, and they are different in kind.**

*If the goal is the suite number*: SSE, on volume alone. But encryption in a
local fake is largely theatre — storing plaintext and echoing back
`x-amz-server-side-encryption` would pass many of these while implementing
nothing real. That is a legitimate choice for a test double, but it should be a
deliberate one rather than a side effect of chasing the count.

*If the goal is a useful dev/test fake*: **ACL enforcement** is the better
target despite the smaller count. It is currently a static stub that claims
`FULL_CONTROL` for everyone, which means a caller cannot use FakeS3 to test
that their own permission handling works — the fake always says yes. That is
the kind of gap that silently invalidates someone's tests, unlike missing
encryption, which fails loudly.

Object lock and bucket logging both look like poor value here.

### The 4 remaining POST auth failures

`test_post_object_invalid_signature`, `_invalid_access_key`,
`_missing_signature` and `_authenticated_request_bad_access_key` all expect
403. They need HMAC verification of the policy signature, which needs the
secret key, so they can only pass in `static`/`strict` mode — and the suite
runs against the default `noauth`. Implementing it would not move these
numbers; it would only matter to someone running the suite in strict mode.
Deliberately left alone.

## POST object — implemented

Browser form uploads: `POST /<bucket>` with `multipart/form-data`, dispatched
on content type so a `?delete` bulk delete and a plain POST still behave as
before.

The body is parsed with `Plug.Parsers` *inside the handler* rather than in the
plug pipeline. Every other route streams its body straight to disk, and
installing a parser globally would buffer object uploads that are deliberately
never held in memory.

Covered: the upload itself; `${filename}` substitution; `Content-Type` and
`x-amz-meta-*`; `success_action_status` (200/201/204, anything else falling
back to 204); `success_action_redirect` returning 303; and the base64 policy
document — expiration, `eq`, `starts-with`, `content-length-range`, bidirectional
field/condition matching, `x-ignore-*` exemption, and case-insensitive
operators and field names. 23 tests in `test/post_object_test.exs`.

The policy is treated as **request validation, not authentication**: it is
supplied by the client and states what the form may contain, so it is enforced
in every auth mode. Verifying the signature *over* the policy needs the secret
key, so that stays with the configured mode — see above.

Four things that were each a real bug, worth recording because none was obvious
from the spec:

- **Every form field arrives as a `Plug.Upload`.** Clients that put a filename
  on every part — `requests`' `files=`, and many browser helpers — make Plug
  parse ordinary fields as uploads. Only `file` is the body; the rest are read
  back as text. Before this, the very first POST test 500'd.
- **`${filename}` must be resolved before conditions are checked**, or
  `["starts-with", "$key", "foo"]` sees the literal `${filename}`.
- **`PostResponse` carries no xmlns.** With a default namespace, a browser's
  plain `find("Key")` returns nothing.
- **Elixir's `DateTime.from_iso8601` accepts any separator**, so Python's
  `str(datetime)` ("2026-08-21 12:00:00+00:00") parsed as a valid expiration.
  Now matched against a strict ISO 8601 pattern first.

### Bucket GET subresource dispatch, corrected

`success_action_redirect` sends the browser back to the bucket URL with
`?bucket=&key=&etag=` appended. The old dispatch treated *any* unrecognised
query parameter as an unimplemented subresource and answered 501; S3 answers
with a plain listing. Replaced the heuristic with an explicit list of the
bucket GET subresources S3 defines, mirroring what the PUT side already does.
`?lifecycle` and friends still 501.

### What it bought

| | passed | failed | skipped | errors |
|---|---|---|---|---|
| before POST object | 217 | 545 | 94 | 0 |
| after | **249** | 495 | 94 | 0 |

+32, zero regressions (`PASSED` sets diffed either side). All 32 are POST
tests — the subresource-dispatch correction gained nothing on its own, it just
unblocked the redirect test.

## Versioning — implemented

Enabling versioning does not rewrite anything already on disk: the current
version of a key stays exactly where an unversioned object lives
(`objects/<key>`, `meta/<key>.json`), and only superseded versions move into
parallel `versions/` and `versions_meta/` trees. Every unversioned code path is
untouched. Versions of key `a/b` live under `versions/a/b.d/<version_id>`; the
`.d` suffix stops the directory holding versions of key `a` from colliding with
the one that has to contain `a/b`.

A delete marker is metadata with no content file, so an ordinary read reports
not-found without any special casing.

Covered: `PUT`/`GET ?versioning` (Enabled/Suspended, and "never configured"
stays distinguishable from Suspended); versioned writes returning
`x-amz-version-id`; `?versionId` on GET/HEAD/DELETE; delete markers, including
405 when addressed directly and 404 with `x-amz-delete-marker` when hit
implicitly; deleting the current version promoting the previous one back;
Suspended reusing the `null` id and replacing rather than accumulating;
`ListObjectVersions` with real versions, `IsLatest`, and `DeleteMarker`
elements; and `bucket_empty?` accounting for history so DeleteBucket cannot
orphan versions.

Version ids are `<zero-padded-microseconds>-<random>`, so lexicographic order
is creation order. 20 tests in `test/versioning_test.exs`.

Two deliberate simplifications:

- `ListObjectVersions` paginates by key, not by key+version, so every version
  of a key in a page is returned together. S3 can split a key's versions across
  pages via `version-id-marker`; that would need a second cursor and nothing
  observed here depends on it.
- Version and DeleteMarker elements are emitted grouped rather than interleaved
  in key order. Clients sort them into separate lists regardless.

### What it bought

| | passed | failed | skipped | errors |
|---|---|---|---|---|
| before versioning | 199 | 545 | 94 | 0 |
| after | **217** | 527 | 94 | 0 |

+18 tests, zero regressions (`PASSED` sets diffed either side). The 18 are the
core versioning suite: `test_versioning_obj_create_read_remove`,
`test_delete_marker_versioned`, `test_versioning_obj_suspend_versions`,
`test_versioning_multi_object_delete`, and similar.

Worth saying plainly: the previous STATE.md called versioning "the only way to
move the number", which implied a large payoff. It moved it by 18. The estimate
was wrong — most of the tests that *mention* versioning fail on some other
missing feature they combine it with.

### A regression this caught

The first full run after versioning went to **667 errors** — worse than any
point in this work. Cause: bulk delete gathered `<Key>` and `<VersionId>` into
two separate flat lists, losing the pairing, so it ignored versions entirely.
`nuke_bucket` empties a versioned bucket exactly that way, so no versioned
bucket could ever be deleted, and the old `BucketNotEmpty` cascade came back.
Fixed by parsing each `<Object>` element whole. Regression tests cover both the
versioned bulk delete and the marker-inserting form.

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
