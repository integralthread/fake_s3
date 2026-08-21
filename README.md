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
DeleteObjects (bulk), CopyObject (with `x-amz-metadata-directive`).

Buckets: CreateBucket, ListBuckets, HeadBucket, DeleteBucket,
ListObjects (v1), ListObjectsV2, GetBucketLocation, GetBucketVersioning,
GetBucketAcl.

Multipart: CreateMultipartUpload, UploadPart, CompleteMultipartUpload,
AbortMultipartUpload, ListParts, ListMultipartUploads.

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
- **No versioning, lifecycle, ACL enforcement, or encryption.** The ACL and
  versioning endpoints return static stub documents so SDK calls succeed.
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
