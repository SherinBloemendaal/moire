import Foundation
@testable import MoireKit
import Testing

/// Vectors from the AWS Signature Version 4 test suite (service `service`, 2015-08-30) and from
/// the S3 documentation's header signing examples (2013-05-24).
struct AWSSignerTests {
    private let suite = AWSSigner(
        credentials: AWSCredentials(accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
        region: "us-east-1",
        service: "service"
    )
    private let suiteHeaders = [("Host", "example.amazonaws.com"), ("X-Amz-Date", "20150830T123600Z")]

    private func signature(_ authorization: String) -> String {
        String(authorization.split(separator: "=").last ?? "")
    }

    @Test func `get-vanilla`() {
        let authorization = suite.authorization(method: "GET", encodedPath: "/", query: [], headers: suiteHeaders, payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20150830T123600Z")
        #expect(authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func `get-vanilla canonical request`() {
        let (request, signed) = AWSSigner.canonicalRequest(method: "GET", encodedPath: "/", query: [], headers: suiteHeaders, payloadHash: AWSSigner.emptyPayloadHash)
        #expect(request == "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(signed == "host;x-amz-date")
    }

    @Test func `get-vanilla-query-order-key-case sorts the query`() {
        let authorization = suite.authorization(
            method: "GET", encodedPath: "/", query: [("Param2", "value2"), ("Param1", "value1")],
            headers: suiteHeaders, payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20150830T123600Z"
        )
        #expect(signature(authorization) == "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")
    }

    @Test func `get-vanilla-empty-query-key`() {
        let authorization = suite.authorization(
            method: "GET", encodedPath: "/", query: [("Param1", "value1")],
            headers: suiteHeaders, payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20150830T123600Z"
        )
        #expect(signature(authorization) == "a67d582fa61cc504c4bae71f336f98b97f1ea3c7a6bfe1b6e45aec72011b9aeb")
    }

    @Test func `get-unreserved keeps unreserved characters`() {
        let path = "/" + AWSSigner.encode("-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", keepSlash: true)
        let authorization = suite.authorization(method: "GET", encodedPath: path, query: [], headers: suiteHeaders, payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20150830T123600Z")
        #expect(signature(authorization) == "07ef7494c76fa4850883e2b006601f940f8a34d404d0cfa977f52a65bbf5f24f")
    }

    @Test func `post-vanilla`() {
        let authorization = suite.authorization(method: "POST", encodedPath: "/", query: [], headers: suiteHeaders, payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20150830T123600Z")
        #expect(signature(authorization) == "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b")
    }

    @Test func `IAM ListUsers example from the signing guide`() {
        let signer = AWSSigner(credentials: suite.credentials, region: "us-east-1", service: "iam")
        let authorization = signer.authorization(
            method: "GET", encodedPath: "/", query: [("Action", "ListUsers"), ("Version", "2010-05-08")],
            headers: [
                ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8"),
                ("Host", "iam.amazonaws.com"),
                ("X-Amz-Date", "20150830T123600Z"),
            ],
            payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20150830T123600Z"
        )
        #expect(authorization == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    private let s3 = AWSSigner(
        credentials: AWSCredentials(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        region: "us-east-1",
        service: "s3"
    )

    private func s3Headers(_ extra: [(String, String)] = []) -> [(String, String)] {
        [("Host", "examplebucket.s3.amazonaws.com"), ("x-amz-date", "20130524T000000Z"), ("x-amz-content-sha256", AWSSigner.emptyPayloadHash)] + extra
    }

    @Test func `S3 GetObject with a range`() {
        let authorization = s3.authorization(
            method: "GET", encodedPath: "/test.txt", query: [], headers: s3Headers([("Range", "bytes=0-9")]),
            payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20130524T000000Z"
        )
        #expect(authorization == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func `S3 GET bucket lifecycle signs an empty query value`() {
        let authorization = s3.authorization(
            method: "GET", encodedPath: "/", query: [("lifecycle", "")], headers: s3Headers(),
            payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20130524T000000Z"
        )
        #expect(signature(authorization) == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    @Test func `S3 list objects`() {
        let authorization = s3.authorization(
            method: "GET", encodedPath: "/", query: [("max-keys", "2"), ("prefix", "J")], headers: s3Headers(),
            payloadHash: AWSSigner.emptyPayloadHash, amzDate: "20130524T000000Z"
        )
        #expect(signature(authorization) == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")
    }

    @Test func `encodes like RFC 3986 and keeps slashes only in paths`() {
        #expect(AWSSigner.encode("a b/c+d~é") == "a%20b%2Fc%2Bd~%C3%A9")
        #expect(AWSSigner.encode("dir/file name.txt", keepSlash: true) == "dir/file%20name.txt")
    }

    @Test func `formats x-amz-date in UTC`() {
        #expect(AWSSigner.amzDate(Date(timeIntervalSince1970: 1_440_938_160)) == "20150830T123600Z")
    }

    @Test func `collapses and trims header values`() {
        let (request, _) = AWSSigner.canonicalRequest(
            method: "GET", encodedPath: "/", query: [],
            headers: [("My-Header1", "  value1  "), ("my-header2", "a   b   c"), ("Host", "h")],
            payloadHash: "x"
        )
        #expect(request.contains("my-header1:value1\nmy-header2:a b c\n"))
    }
}
