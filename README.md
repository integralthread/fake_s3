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

The server supports AWS CLI basic operations. Use path-style addressing:

```sh
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

aws --endpoint-url http://127.0.0.1:9000 s3 ls
aws --endpoint-url http://127.0.0.1:9000 s3 mb s3://demo-bucket
aws --endpoint-url http://127.0.0.1:9000 s3 cp README.md s3://demo-bucket/README.md
aws --endpoint-url http://127.0.0.1:9000 s3 ls s3://demo-bucket
aws --endpoint-url http://127.0.0.1:9000 s3 rm s3://demo-bucket/README.md
aws --endpoint-url http://127.0.0.1:9000 s3 rb s3://demo-bucket
```
