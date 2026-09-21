# FakeS3

Local, filesystem-backed S3-compatible server for development and tests.

## Running

Run on the default host/port:

```sh
mix run --no-halt
```

Run on a specific port:

```sh
FAKES3_PORT=9000 mix run --no-halt
```

You can also set the host and data directory:

```sh
FAKES3_HOST=0.0.0.0 FAKES3_PORT=9000 FAKES3_DATA_DIR=./.fakes3 mix run --no-halt
```

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `FAKES3_HOST` | `127.0.0.1` | |
| `FAKES3_PORT` | `4569` | |
| `FAKES3_DATA_DIR` | `./.fakes3` | |
| `FAKES3_MODE` | `noauth` | `noauth`, `static`, or `strict` |
| `FAKES3_ACCESS_KEY` | | required for `static`/`strict` |
| `FAKES3_SECRET_KEY` | | required for `static`/`strict` |
| `FAKES3_REGION` | `us-east-1` | |
| `FAKES3_LOG_LEVEL` | `info` | `debug` logs canonical requests on signature mismatch |
| `FAKES3_MAX_BODY_BYTES` | unset | rejects larger uploads with `EntityTooLarge` |

Invalid numeric values are logged and ignored rather than crashing startup.

### Auth modes

- **noauth** — accept everything. Best default for local development.
- **static** — validate the access key; log signature mismatches but allow them.
- **strict** — reject on signature mismatch. Supports both `Authorization`
  header signing and presigned URLs (`X-Amz-Signature` in the query string),
  including expiry checks.

## Supported operations

Objects: PutObject, GetObject (incl. `Range`), HeadObject, DeleteObject,
DeleteObjects (bulk), CopyObject (with `x-amz-metadata-directive`). GET, HEAD
and DELETE accept `?versionId=`.

Buckets: CreateBucket, ListBuckets, HeadBucket, DeleteBucket,
ListObjects (v1), ListObjectsV2, ListObjectVersions, GetBucketLocation,
GetBucketVersioning, PutBucketVersioning, GetBucketAcl.

Multipart: CreateMultipartUpload, UploadPart, CompleteMultipartUpload,
AbortMultipartUpload, ListParts, ListMultipartUploads.

Browser form uploads: `POST /<bucket>` with `multipart/form-data`, including
`${filename}`, `success_action_status`, `success_action_redirect`, and the
base64 policy document (expiration, `eq`, `starts-with`,
`content-length-range`). The policy is enforced in every auth mode, since it is
supplied by the client and describes what its own form may contain; the
signature *over* the policy is only checked in `static`/`strict`.

Request bodies framed with `Content-Encoding: aws-chunked` (what SDKs send
when checksums or streaming signatures are enabled) are decoded before
storage, so object bytes and ETags match the payload rather than the framing.

Errors are returned as S3 XML (`<Error><Code>…`) on every path, including
unrouted requests and auth rejections.

## Known divergences from S3

These are deliberate, and are the things most likely to surprise you:

- **Keys and prefixes cannot collide.** S3's keyspace is flat, so `a` and
  `a/b` can both exist. Objects here are files, so they cannot. The second
  write is rejected with `InvalidArgument` rather than silently discarded.
- **Multipart parts have no minimum size.** S3 requires every part except the
  last to be at least 5 MB. That is not enforced, so tests can use tiny parts.
- **No lifecycle, ACL enforcement, or encryption.** The ACL endpoints return
  static stub documents so SDK calls succeed.
- **Versioning is supported but simplified.** Enabled and Suspended both work,
  along with delete markers and `?versionId`. Two shortcuts:
  ListObjectVersions paginates by key rather than key+version, so a key's
  versions are never split across pages (no `version-id-marker`), and Version
  and DeleteMarker entries are grouped rather than interleaved in key order.
- **`NextMarker`/`NextContinuationToken` are real keys**, not opaque cursors.
  They resume correctly but do not match S3's values byte for byte.
- **Signature verification accepts two query canonicalisations.** `a+b` in a
  query string is ambiguous — a space under form encoding, a literal `+` under
  RFC 3986. The AWS CLI normalises to `%20` before signing; Req signs the
  bytes as sent. Both are accepted.

## Req + req_s3 examples

```elixir
Mix.install([
  {:req, "~> 0.5.0"},
  {:req_s3, "~> 0.2.3"}
])

endpoint = "http://127.0.0.1:9000"

req =
  Req.new()
  |> ReqS3.attach(
    aws_endpoint_url_s3: endpoint,
    aws_sigv4: [
      access_key_id: "test",
      secret_access_key: "test",
      region: "us-east-1"
    ]
  )

bucket = "demo-bucket"
key = "hello.txt"

Req.put!(req, url: "s3://#{bucket}")
Req.put!(req, url: "s3://#{bucket}/#{key}", body: "hello")
Req.get!(req, url: "s3://#{bucket}/#{key}").body
```

## AWS CLI testing

Use path-style addressing:

```sh
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

aws --endpoint-url http://127.0.0.1:9000 s3 ls
aws --endpoint-url http://127.0.0.1:9000 s3 mb s3://demo-bucket
aws --endpoint-url http://127.0.0.1:9000 s3 cp README.md s3://demo-bucket/README.md
aws --endpoint-url http://127.0.0.1:9000 s3 ls s3://demo-bucket
aws --endpoint-url http://127.0.0.1:9000 s3 rm s3://demo-bucket/README.md --recursive
aws --endpoint-url http://127.0.0.1:9000 s3 rb s3://demo-bucket
```

`test_aws_cli.sh` runs a broader suite against a running server:

```sh
mix run --no-halt &
./test_aws_cli.sh http://127.0.0.1:4569
```

## Tests

```sh
mix test
```

## ceph/s3-tests

[ceph/s3-tests](https://github.com/ceph/s3-tests) is a third-party S3
compatibility suite. `mise run bootstrap` clones it into `vendor/s3-tests`
(gitignored) and builds a Python venv for it:

```sh
mise run bootstrap      # once
mise run server         # in another shell
mise run s3-tests
```

`s3tests.conf` at the repo root points the suite at `127.0.0.1:4569`, and
`mise.toml` exports it as `S3TEST_CONF`. The suite expects several distinct
users; FakeS3's default `noauth` mode accepts any key, so they all share one
store.

Pass pytest arguments after `--`:

```sh
mise run s3-tests -- s3tests/functional/test_s3.py::test_bucket_list_empty
mise run s3-tests -- s3tests/functional/test_s3.py -m 'not fails_on_aws'
```

Most of the suite exercises features FakeS3 does not implement (versioning,
lifecycle, encryption, IAM, tagging), so a large number of failures is
expected. Nothing here is wired into `mise run check`.

## Debug endpoints

- `GET /__health` — liveness check.
- `GET /__debug/objects` — JSON dump of every stored object and its metadata.

Every response carries `x-amz-request-id`, and that id is attached to the
logs emitted while handling the request.

## Storage layout

```
DATA_DIR/buckets/<bucket>/bucket.json          bucket metadata
                         /objects/<key>        object content
                         /meta/<key>.json      object metadata
                         /tmp/                 staging for temp+rename writes
                         /uploads/<id>/        in-flight multipart uploads
```

`tmp/` and `uploads/` are siblings of `objects/` so that partial writes are
never visible to listings and never block bucket deletion.

## Bedrock local development

The Bedrock 0.7.2 S3 adapter is exercised directly by our test suite, through
ExAws/Req with strict SigV4 authentication. It is a **test-only dependency**;
FakeS3 does not start a Bedrock cluster.

From this repository:

```sh
mise run bedrock:server
# In another terminal, create the bucket (safe to repeat):
mise run bedrock:bucket
```

Or manage the server with `mise exec -- pitchfork start fake_s3` and
`mise exec -- pitchfork stop fake_s3`. The dedicated development profile uses
loopback port 4569 and persistent `.fakes3-bedrock/` storage. Its credentials are
fixed local-development values, not AWS credentials. Strict mode also requires signed
health requests; use the bucket task as an authenticated readiness check.

In the consuming application:

```elixir
config :bedrock, Bedrock.ObjectStorage,
  backend: :s3,
  s3: [
    bucket: "bedrock",
    access_key_id: "bedrock-local",
    secret_access_key: "bedrock-local-secret",
    region: "us-east-1",
    scheme: "http://",
    host: "127.0.0.1",
    port: 4569
  ]
```

Use an **unversioned bucket** for this profile. AshBedrock still needs its own
Bedrock cluster/repo configuration; FakeS3 supplies only the object-storage service.

### Concurrency and recovery contract

- PUT honors `If-None-Match: *` and strong `If-Match` ETags. Rejected writes return
  S3 XML `PreconditionFailed` (412) without changing the object. ETags are the CAS
  tokens; S3 VersionId is not needed by Bedrock.
- Requests sharing a data directory are serialized within one BEAM VM. This
  includes ordinary writes, COPY, multipart completion, deletes, and reads, so
  other operations cannot race a conditional write. **Run only one server VM per
  data directory**; this is not a cross-process filesystem lock.
- GET/HEAD/Range capture the object bytes under that lock, preserving their ETag
  and length. This buffers the object in memory and deliberately prioritizes
  local-development correctness over high-throughput or huge-object workloads.
- An undo journal under `.publications/` protects body/metadata publication for
  PUT, COPY, multipart completion, and unversioned DELETE. Interrupted publication
  is recovered before the next request, including after a process restart. Data
  and metadata staging files are synced before publication. Metadata staging is
  outside object listings and cleared during recovery.
- Corrupt metadata and storage I/O failures return server errors rather than
  pretending that an object or prefix is absent. Delete reports failed removals.
- Tests cover process interruption and listener restart. This is **not a claim
  of host-power-loss durability or production S3 equivalence**: directory fsync,
  multi-VM coordination, and complete versioning/multipart crash semantics remain
  outside the local Bedrock profile. Do not edit storage files while serving.

### Compatibility tests

```sh
mise run test:bedrock
FAKES3_PORT=0 mise run check
```

The dedicated suite uses isolated temporary stores and covers the actual Bedrock
adapter's CRUD, conditional-create races, CAS races, binary values and ETags,
1,003-key pagination, prefix/limit handling, a deleted continuation key, storage
errors (including a failed second listing page), interrupted publication recovery,
and persistent listener restart. The full suite also retains the existing S3
client, multipart, versioning, range, and authentication tests.
