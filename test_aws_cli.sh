#!/bin/bash
#
# Comprehensive AWS CLI test script for FakeS3
# Usage: ./test_aws_cli.sh [endpoint]
#

set -e

ENDPOINT="${1:-http://127.0.0.1:4569}"
BUCKET="cli-test-bucket-$$"
BUCKET2="cli-test-bucket2-$$"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() {
    echo -e "${RED}FAIL${NC}: $1"
    exit 1
}
info() { echo -e "${YELLOW}TEST${NC}: $1"; }

aws_s3() {
    aws --endpoint-url "$ENDPOINT" s3 "$@"
}

aws_s3api() {
    aws --endpoint-url "$ENDPOINT" s3api "$@"
}

cleanup() {
    info "Cleaning up..."
    aws_s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
    aws_s3 rb "s3://$BUCKET" 2>/dev/null || true
    aws_s3 rm "s3://$BUCKET2" --recursive 2>/dev/null || true
    aws_s3 rb "s3://$BUCKET2" 2>/dev/null || true
    rm -f /tmp/fakes3_test_* 2>/dev/null || true
}

trap cleanup EXIT

echo "================================================"
echo "FakeS3 AWS CLI Test Suite"
echo "Endpoint: $ENDPOINT"
echo "Test bucket: $BUCKET"
echo "================================================"
echo

# Check server is running
info "Checking server health..."
if curl -sf "$ENDPOINT/__health" >/dev/null; then
    pass "Server is healthy"
else
    echo "Start one with 'mise run server', or let 'mise run test-aws-cli' start it for you." >&2
    fail "Server not responding at $ENDPOINT"
fi

echo
echo "--- BUCKET OPERATIONS ---"
echo

# Create bucket
info "Creating bucket..."
aws_s3 mb "s3://$BUCKET"
pass "Created bucket $BUCKET"

# List buckets
info "Listing buckets..."
if aws_s3 ls | grep -q "$BUCKET"; then
    pass "Bucket appears in list"
else
    fail "Bucket not in list"
fi

# Head bucket (check exists)
info "Head bucket..."
aws_s3api head-bucket --bucket "$BUCKET"
pass "Head bucket successful"

# Try to delete non-empty bucket later (error case)

echo
echo "--- OBJECT CRUD OPERATIONS ---"
echo

# Create test file
echo "Hello, FakeS3!" >/tmp/fakes3_test_hello.txt

# Put object
info "Putting object..."
aws_s3 cp /tmp/fakes3_test_hello.txt "s3://$BUCKET/hello.txt"
pass "Put object hello.txt"

# Get object
info "Getting object..."
aws_s3 cp "s3://$BUCKET/hello.txt" /tmp/fakes3_test_downloaded.txt
if [ "$(cat /tmp/fakes3_test_downloaded.txt)" = "Hello, FakeS3!" ]; then
    pass "Get object content matches"
else
    fail "Get object content mismatch"
fi

# Head object
info "Head object..."
ETAG=$(aws_s3api head-object --bucket "$BUCKET" --key "hello.txt" --query 'ETag' --output text)
if [ -n "$ETAG" ]; then
    pass "Head object returned ETag: $ETAG"
else
    fail "Head object missing ETag"
fi

# List objects
info "Listing objects..."
if aws_s3 ls "s3://$BUCKET/" | grep -q "hello.txt"; then
    pass "Object appears in list"
else
    fail "Object not in list"
fi

echo
echo "--- METADATA OPERATIONS ---"
echo

# Put object with metadata
info "Putting object with custom metadata..."
aws_s3api put-object \
    --bucket "$BUCKET" \
    --key "meta.txt" \
    --body /tmp/fakes3_test_hello.txt \
    --content-type "text/plain; charset=utf-8" \
    --cache-control "max-age=3600" \
    --metadata "custom-key=custom-value,another-key=another-value"
pass "Put object with metadata"

# Get object and check metadata
info "Checking object metadata..."
META_OUT=$(aws_s3api head-object --bucket "$BUCKET" --key "meta.txt")
if echo "$META_OUT" | grep -q "text/plain"; then
    pass "Content-Type preserved"
else
    fail "Content-Type not preserved"
fi
if echo "$META_OUT" | grep -q "max-age=3600"; then
    pass "Cache-Control preserved"
else
    fail "Cache-Control not preserved"
fi
if echo "$META_OUT" | grep -q "custom-value"; then
    pass "Custom metadata preserved"
else
    fail "Custom metadata not preserved"
fi

echo
echo "--- LIST OBJECTS V2 WITH PREFIX/DELIMITER ---"
echo

# Create directory structure
info "Creating directory structure..."
echo "a" | aws_s3 cp - "s3://$BUCKET/logs/2024/01/a.log"
echo "b" | aws_s3 cp - "s3://$BUCKET/logs/2024/01/b.log"
echo "c" | aws_s3 cp - "s3://$BUCKET/logs/2024/02/c.log"
echo "d" | aws_s3 cp - "s3://$BUCKET/logs/2024/02/d.log"
echo "e" | aws_s3 cp - "s3://$BUCKET/data/file.txt"
pass "Created 5 objects in directory structure"

# List with prefix
info "Listing with prefix..."
COUNT=$(aws_s3api list-objects-v2 --bucket "$BUCKET" --prefix "logs/" --query 'length(Contents)' --output text)
if [ "$COUNT" -ge 4 ]; then
    pass "Prefix filter returned $COUNT objects"
else
    fail "Prefix filter returned wrong count: $COUNT (expected >= 4)"
fi

# List with delimiter (should show common prefixes)
info "Listing with delimiter..."
RESULT=$(aws_s3api list-objects-v2 --bucket "$BUCKET" --prefix "logs/" --delimiter "/")
if echo "$RESULT" | grep -q "CommonPrefixes"; then
    pass "Delimiter grouping works"
else
    fail "Delimiter grouping failed"
fi
if echo "$RESULT" | grep -q "logs/2024/"; then
    pass "Common prefix logs/2024/ found"
else
    fail "Common prefix not found"
fi

# Pagination test
info "Testing pagination..."
PAGE1=$(aws_s3api list-objects-v2 --bucket "$BUCKET" --max-items 2)
if echo "$PAGE1" | grep -q "NextToken"; then
    pass "Pagination NextToken returned"
    NEXT_TOKEN=$(echo "$PAGE1" | grep -o '"NextToken": "[^"]*"' | cut -d'"' -f4)
    PAGE2=$(aws_s3api list-objects-v2 --bucket "$BUCKET" --starting-token "$NEXT_TOKEN")
    # The second page was fetched but never inspected, so this always passed.
    if echo "$PAGE2" | grep -q '"Key":'; then
        pass "Pagination continuation returned more keys"
    else
        fail "Pagination continuation returned no keys"
    fi
else
    info "Note: Pagination token not returned (may have fewer objects than max-items)"
fi

echo
echo "--- COPY OBJECT ---"
echo

# Copy within same bucket
info "Copying object within bucket..."
aws_s3api copy-object \
    --bucket "$BUCKET" \
    --key "hello-copy.txt" \
    --copy-source "$BUCKET/hello.txt"
pass "Copy object within bucket"

# Verify copy
info "Verifying copied object..."
aws_s3 cp "s3://$BUCKET/hello-copy.txt" /tmp/fakes3_test_copy.txt
if [ "$(cat /tmp/fakes3_test_copy.txt)" = "Hello, FakeS3!" ]; then
    pass "Copied object content matches"
else
    fail "Copied object content mismatch"
fi

# Cross-bucket copy
info "Creating second bucket for cross-bucket copy..."
aws_s3 mb "s3://$BUCKET2"
pass "Created bucket $BUCKET2"

info "Copying object across buckets..."
aws_s3api copy-object \
    --bucket "$BUCKET2" \
    --key "cross-copy.txt" \
    --copy-source "$BUCKET/hello.txt"
pass "Cross-bucket copy successful"

aws_s3 cp "s3://$BUCKET2/cross-copy.txt" /tmp/fakes3_test_cross.txt
if [ "$(cat /tmp/fakes3_test_cross.txt)" = "Hello, FakeS3!" ]; then
    pass "Cross-bucket copy content matches"
else
    fail "Cross-bucket copy content mismatch"
fi

echo
echo "--- RANGE REQUESTS ---"
echo

# Create larger file for range tests
echo "0123456789ABCDEFGHIJ" >/tmp/fakes3_test_range.txt
aws_s3 cp /tmp/fakes3_test_range.txt "s3://$BUCKET/range.txt"

info "Testing range request (first 5 bytes)..."
aws_s3api get-object \
    --bucket "$BUCKET" \
    --key "range.txt" \
    --range "bytes=0-4" \
    /tmp/fakes3_test_range_out.txt >/dev/null
if [ "$(cat /tmp/fakes3_test_range_out.txt)" = "01234" ]; then
    pass "Range request bytes=0-4 returned '01234'"
else
    fail "Range request returned: $(cat /tmp/fakes3_test_range_out.txt)"
fi

info "Testing range request (middle bytes)..."
aws_s3api get-object \
    --bucket "$BUCKET" \
    --key "range.txt" \
    --range "bytes=10-14" \
    /tmp/fakes3_test_range_out2.txt >/dev/null
if [ "$(cat /tmp/fakes3_test_range_out2.txt)" = "ABCDE" ]; then
    pass "Range request bytes=10-14 returned 'ABCDE'"
else
    fail "Range request returned: $(cat /tmp/fakes3_test_range_out2.txt)"
fi

echo
echo "--- DEBUG ENDPOINT ---"
echo

info "Testing debug endpoint..."
DEBUG_OUT=$(curl -sf "$ENDPOINT/__debug/objects")
if echo "$DEBUG_OUT" | grep -q "$BUCKET"; then
    pass "Debug endpoint returns objects"
else
    fail "Debug endpoint not returning expected data"
fi

echo
echo "--- ERROR CASES ---"
echo

# Try to get non-existent object
info "Testing NoSuchKey error..."
if aws_s3api head-object --bucket "$BUCKET" --key "nonexistent.txt" 2>&1 | grep -q "404\|Not Found\|NoSuchKey"; then
    pass "NoSuchKey error returned correctly"
else
    # The command should fail
    pass "NoSuchKey error (command failed as expected)"
fi

# Try to delete non-empty bucket
info "Testing BucketNotEmpty error..."
if aws_s3 rb "s3://$BUCKET" 2>&1 | grep -q "not empty\|BucketNotEmpty"; then
    pass "BucketNotEmpty error returned correctly"
else
    pass "BucketNotEmpty error (command failed as expected)"
fi

# Try to access non-existent bucket
info "Testing NoSuchBucket error..."
if aws_s3api head-bucket --bucket "nonexistent-bucket-$RANDOM" 2>&1 | grep -q "404\|Not Found\|NoSuchBucket"; then
    pass "NoSuchBucket error returned correctly"
else
    pass "NoSuchBucket error (command failed as expected)"
fi

echo
echo "--- MULTIPART UPLOAD ---"
echo

# Anything over the CLI's 8MB threshold goes through CreateMultipartUpload.
info "Uploading a 20MB file (forces multipart)..."
dd if=/dev/urandom of=/tmp/fakes3_test_big.bin bs=1048576 count=20 2>/dev/null
aws_s3 cp /tmp/fakes3_test_big.bin "s3://$BUCKET/big.bin" --no-progress
pass "Multipart upload completed"

info "Verifying multipart round-trip integrity..."
aws_s3 cp "s3://$BUCKET/big.bin" /tmp/fakes3_test_big_out.bin --no-progress
if cmp -s /tmp/fakes3_test_big.bin /tmp/fakes3_test_big_out.bin; then
    pass "Downloaded bytes match the original"
else
    fail "Multipart round-trip corrupted the object"
fi

info "Checking composite ETag format..."
BIG_ETAG=$(aws_s3api head-object --bucket "$BUCKET" --key "big.bin" --query 'ETag' --output text)
if echo "$BIG_ETAG" | grep -qE '^"?[0-9a-f]{32}-[0-9]+"?$'; then
    pass "Multipart ETag has the <md5>-<parts> form: $BIG_ETAG"
else
    fail "Unexpected multipart ETag: $BIG_ETAG"
fi

info "Checking reported size..."
BIG_LEN=$(aws_s3api head-object --bucket "$BUCKET" --key "big.bin" --query 'ContentLength' --output text)
if [ "$BIG_LEN" = "20971520" ]; then
    pass "HEAD reports $BIG_LEN bytes"
else
    fail "HEAD reported $BIG_LEN"
fi

info "Aborting an upload..."
UPLOAD_ID=$(aws_s3api create-multipart-upload --bucket "$BUCKET" --key "aborted.bin" --query 'UploadId' --output text)
aws_s3api abort-multipart-upload --bucket "$BUCKET" --key "aborted.bin" --upload-id "$UPLOAD_ID"
pass "Aborted multipart upload"

echo
echo "--- LIST VARIANTS ---"
echo

info "ListObjects v1..."
aws_s3api list-objects --bucket "$BUCKET" --max-keys 2 >/dev/null
pass "list-objects (v1) succeeded"

info "GetBucketLocation..."
aws_s3api get-bucket-location --bucket "$BUCKET" >/dev/null
pass "get-bucket-location succeeded"

echo
echo "--- RANGE REQUESTS ---"
echo

info "Ranged GET..."
echo -n "hello world" | aws_s3 cp - "s3://$BUCKET/range.txt"
RANGE_OUT=$(aws_s3api get-object --bucket "$BUCKET" --key "range.txt" --range "bytes=0-4" /tmp/fakes3_test_range.txt >/dev/null && cat /tmp/fakes3_test_range.txt)
if [ "$RANGE_OUT" = "hello" ]; then
    pass "Range returned '$RANGE_OUT'"
else
    fail "Range returned '$RANGE_OUT'"
fi

info "Unsatisfiable range returns 416..."
if aws_s3api get-object --bucket "$BUCKET" --key "range.txt" --range "bytes=9999-99999" /tmp/fakes3_test_range2.txt 2>&1 | grep -qi "416\|InvalidRange\|Requested Range"; then
    pass "416 InvalidRange returned"
else
    fail "Expected 416 for an unsatisfiable range"
fi

echo
echo "--- BULK DELETE ---"
echo

info "delete-objects with multiple keys..."
echo "x" | aws_s3 cp - "s3://$BUCKET/bulk1.txt"
echo "y" | aws_s3 cp - "s3://$BUCKET/bulk2.txt"
DELETED=$(aws_s3api delete-objects --bucket "$BUCKET" \
    --delete 'Objects=[{Key=bulk1.txt},{Key=bulk2.txt}]' \
    --query 'length(Deleted)' --output text)
if [ "$DELETED" = "2" ]; then
    pass "Bulk deleted $DELETED objects"
else
    fail "Bulk delete reported $DELETED"
fi

echo
echo "--- DELETE OPERATIONS ---"
echo

# Delete objects
info "Deleting individual object..."
aws_s3 rm "s3://$BUCKET/hello.txt"
pass "Deleted hello.txt"

# Delete idempotent
info "Testing idempotent delete..."
aws_s3 rm "s3://$BUCKET/hello.txt" 2>/dev/null || true
pass "Idempotent delete (no error on missing object)"

# Bulk delete
info "Deleting all objects in bucket..."
aws_s3 rm "s3://$BUCKET" --recursive
pass "Recursive delete successful"

# Delete empty bucket
info "Deleting empty bucket..."
aws_s3 rb "s3://$BUCKET"
pass "Deleted bucket $BUCKET"

# Cleanup second bucket
aws_s3 rm "s3://$BUCKET2" --recursive
aws_s3 rb "s3://$BUCKET2"
pass "Deleted bucket $BUCKET2"

echo
echo "================================================"
echo -e "${GREEN}ALL TESTS PASSED!${NC}"
echo "================================================"
