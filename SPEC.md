Spec: Fake S3 Server in Elixir

Goal: implement a developer-focused S3-compatible HTTP server that supports the minimum set of S3 operations most apps use, backed by the local filesystem, and suitable for local development and tests. It should be “S3 compatible enough” for AWS SDKs to work with trivial config changes.

Non-goals: durability, HA, lifecycle, versioning, IAM/policies, encryption, full error parity.

⸻

1) Compatibility Targets

Supported clients
	•	AWS SDKs (at least one): aws-sdk-elixir (ExAws), Node AWS SDK, boto3
	•	AWS CLI basic operations (optional; helpful for manual testing)

S3 operations (v1)

Must support:
	1.	PUT Object
	2.	GET Object
	3.	HEAD Object
	4.	DELETE Object
	5.	ListObjectsV2 (prefix, delimiter, continuation token)
	6.	CreateBucket
	7.	ListBuckets
	8.	DeleteBucket (only if empty)
	9.	HEAD Bucket

Nice-to-have:
	•	CopyObject (common for “rename”)
	•	Multipart Upload (later, only if needed)

⸻

2) HTTP API Surface (Routes)

Implement with Phoenix (recommended) or Plug/Cowboy.

Bucket operations
	•	PUT /:bucket → CreateBucket
	•	GET / → ListBuckets
	•	HEAD /:bucket → HeadBucket
	•	DELETE /:bucket → DeleteBucket

Object operations
	•	PUT /:bucket/*key → PutObject
	•	GET /:bucket/*key → GetObject
	•	HEAD /:bucket/*key → HeadObject
	•	DELETE /:bucket/*key → DeleteObject
	•	GET /:bucket?list-type=2 → ListObjectsV2
	•	PUT /:bucket/*key?copy-source=... (or x-amz-copy-source) → CopyObject (optional)

Notes:
	•	Use *key wildcard so keys may contain /.
	•	Preserve query params and headers exactly.

⸻

3) Storage Model

Filesystem-backed store rooted at DATA_DIR.

Layout
	•	Bucket directory: DATA_DIR/buckets/<bucket>/
	•	Object content: DATA_DIR/buckets/<bucket>/objects/<key-path>
	•	Object metadata: DATA_DIR/buckets/<bucket>/meta/<key-path>.json

Where <key-path> mirrors the key’s path segments.

Metadata schema (JSON)

Per object:

{
  "key": "a/b/c.txt",
  "bucket": "my-bucket",
  "size": 123,
  "etag": "\"<md5hex>\"",
  "last_modified": "2026-02-04T12:34:56Z",
  "content_type": "text/plain",
  "headers": {
    "cache-control": "...",
    "content-encoding": "...",
    "content-disposition": "..."
  },
  "user_metadata": {
    "x-amz-meta-foo": "bar"
  }
}

Bucket metadata:

{
  "name": "my-bucket",
  "created_at": "...Z"
}

Atomicity expectations
	•	Writes: stream upload to temp file, compute ETag, then rename into place.
	•	Metadata: write to temp JSON then rename.
	•	Delete: remove content + metadata.

⸻

4) Authentication / Signing

Offer three modes (configurable):
	1.	NoAuth (default for local DX)
	•	Accept any request.
	•	If Authorization present, ignore/parse but do not enforce.
	•	Return S3-shaped errors only for missing resources etc.
	2.	StaticCredentials (optional)
	•	Require access key/secret provided in config.
	•	Validate SigV4 for common requests (best-effort).
	3.	Passthrough/Relaxed SigV4 (optional)
	•	Parse SigV4 for canonical request debugging.
	•	Don’t strictly reject on mismatch unless user requests strict mode.

Recommendation: implement NoAuth + StaticCredentials; keep strictness behind a flag.

⸻

5) Request Handling Requirements

PutObject
	•	Stream request body to disk.
	•	Determine Content-Type:
	•	From header, else infer from key extension, else application/octet-stream.
	•	Compute ETag:
	•	v1: MD5 of body → "md5hex" (quotes included).
	•	Capture:
	•	Standard headers: cache-control, content-encoding, content-disposition, content-language
	•	User metadata: headers x-amz-meta-*
	•	Response:
	•	200 OK
	•	ETag: "<md5hex>"

GetObject
	•	200 OK with streamed file contents.
	•	Headers:
	•	Content-Length, Content-Type, ETag, Last-Modified
	•	Also echo stored optional headers, and x-amz-meta-*
	•	Support Range (nice-to-have, common for some clients):
	•	Range: bytes=start-end → 206 Partial Content

HeadObject
	•	Same headers as GetObject, no body.

DeleteObject
	•	If absent: S3 typically returns 204 (idempotent) — implement that.
	•	If present: delete and return 204 No Content.

ListObjectsV2
	•	Request: GET /:bucket?list-type=2&prefix=&delimiter=&continuation-token=&max-keys=...
	•	Response: XML (AWS SDKs expect XML)
	•	Implement:
	•	prefix filtering
	•	delimiter grouping (CommonPrefixes)
	•	pagination with continuation token
	•	Continuation token format:
	•	base64-encoded last key (lexicographic) or opaque cursor JSON.

CreateBucket
	•	Create bucket dir + metadata.
	•	Return 200 OK (or 409 if exists).

DeleteBucket
	•	Only if empty of objects.
	•	Else return 409 BucketNotEmpty (S3-style XML error).

ListBuckets
	•	XML listing of bucket names + creation date.

HeadBucket
	•	200 OK if exists else 404 NoSuchBucket.

⸻

6) Response Formats

Success responses
	•	Many operations are empty-body with headers.
	•	Lists must be XML.

Error responses (S3-shaped XML)

Implement minimal error envelope:

<Error>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
  <Resource>/bucket/key</Resource>
  <RequestId>...</RequestId>
</Error>

Minimum error codes:
	•	NoSuchBucket (404)
	•	NoSuchKey (404)
	•	BucketAlreadyExists (409) (or BucketAlreadyOwnedByYou)
	•	BucketNotEmpty (409)
	•	InvalidBucketName (400)
	•	InvalidArgument (400)

⸻

7) Bucket/Key Validation Rules

Buckets (simplified)
	•	lowercase letters, numbers, dots, hyphens
	•	3–63 chars
	•	no leading/trailing dot or hyphen
	•	no consecutive dots

Keys
	•	allow any UTF-8 except control chars (practically: accept raw path segments)
	•	URL decode carefully; preserve exact bytes for storage path mapping

Security: prevent path traversal by normalizing and rejecting .. segments after decoding.

⸻

8) Configuration

Via env vars (sensible defaults):
	•	FAKES3_HOST=127.0.0.1
	•	FAKES3_PORT=4569
	•	FAKES3_DATA_DIR=./.fakes3
	•	FAKES3_MODE=noauth|static|strict
	•	FAKES3_ACCESS_KEY=... (static/strict)
	•	FAKES3_SECRET_KEY=...
	•	FAKES3_REGION=us-east-1 (for SigV4 parsing)
	•	FAKES3_LOG_LEVEL=info|debug
	•	FAKES3_MAX_BODY_BYTES (optional)

⸻

9) Observability / DX
	•	Structured logs with request id (x-amz-request-id generated)
	•	Debug endpoint (optional):
	•	GET /__health
	•	GET /__debug/objects (list filesystem state)
	•	Verbose mode prints canonical request when SigV4 is enabled (useful for client debugging)

⸻

10) Concurrency & Performance
	•	Must handle concurrent Put/Get safely:
	•	Writes are atomic via temp+rename.
	•	Reads should tolerate missing file during delete; return consistent errors.
	•	Use streaming:
	•	Plug.Cowboy + sendfile for reads where possible
	•	Streaming upload to avoid buffering entire body

⸻

11) Test Plan

Contract tests (recommended)

Run a suite against:
	•	Your FakeS3 endpoint
	•	AWS S3 (optional, same tests gated)

Test cases:
	•	Put/Get/Head/Delete object
	•	ListObjectsV2 with prefix/delimiter
	•	Pagination and continuation token
	•	Create/Delete bucket and bucket-not-empty behavior
	•	Metadata round-trip (x-amz-meta-*)
	•	Range GET (if implemented)

Tools:
	•	ExUnit + property tests for key handling
	•	Optional: run AWS CLI integration tests in CI (docker)

⸻

12) Implementation Outline (Modules)

Suggested OTP layout:
	•	FakeS3.Application
	•	FakeS3.Router (Phoenix/Plug)
	•	FakeS3.Storage (filesystem operations)
	•	FakeS3.Metadata (read/write JSON, header mapping)
	•	FakeS3.S3XML (encode list/error XML)
	•	FakeS3.Auth (noop/static/strict SigV4 parsing)
	•	FakeS3.RequestId (id + middleware)
	•	FakeS3.Key (decode/normalize/safe-path)

⸻

13) Versioning / Roadmap

v1 (DX-first):
	•	Basic buckets, basic objects, ListV2, metadata, idempotent deletes

v2:
	•	CopyObject
	•	Multipart (create, upload parts, complete) if your app needs it
	•	Better SigV4 strictness

⸻

14) Implementation Status

v1 and v2 are both implemented. Beyond the original scope:

	•	ListObjects v1, DeleteObjects (bulk), GetBucketLocation/Versioning/Acl —
	  needed because the AWS CLI and boto3 call them during ordinary operations.
	•	aws-chunked request body decoding — SDKs frame bodies this way whenever
	  checksums are enabled; storing the framing corrupts the object.
	•	Presigned URL (query string) authentication with expiry checking.
	•	encoding-type=url on listings, so keys containing '%' or '+' survive a
	  round trip through a client that percent-decodes them.

Deliberate divergences are listed under "Known divergences from S3" in the
README. The most significant: keys and prefixes cannot collide, because
objects are stored as files.
