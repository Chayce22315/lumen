import Foundation
import Testing
import LumenKnowledge

@Suite("SHA256")
struct SHA256Tests {
    @Test("standard FIPS 180 test vectors")
    func standardVectors() {
        #expect(SHA256.hexDigest(of: "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hexDigest(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256.hexDigest(of: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        #expect(
            SHA256.hexDigest(of: "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
                == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        )
    }

    @Test("one million 'a' in one shot and streamed in uneven chunks")
    func millionA() {
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        let data = Data(repeating: 0x61, count: 1_000_000)
        #expect(SHA256.hexDigest(of: data) == expected)

        var hasher = SHA256()
        var offset = 0
        var chunk = 1
        while offset < data.count {
            let end = min(data.count, offset + chunk)
            hasher.update(data.subdata(in: offset..<end))
            offset = end
            chunk = chunk * 7 % 4_093 + 1
        }
        #expect(hasher.finalizeHex() == expected)
    }

    @Test("padding boundaries around the 56- and 64-byte block edges", arguments: zip(
        [55, 56, 63, 64, 65, 119, 128],
        [
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
            "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e",
        ]
    ))
    func boundaries(length: Int, digest: String) {
        #expect(SHA256.hexDigest(of: String(repeating: "a", count: length)) == digest)
    }

    @Test("every split point of a two-block message gives the same digest")
    func splitPoints() {
        let message = Array("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8)
        let expected = SHA256.hash(message)
        for split in 0...message.count {
            var hasher = SHA256()
            hasher.update(Array(message[..<split]))
            hasher.update(Array(message[split...]))
            #expect(hasher.finalize() == expected, "split at \(split)")
        }
    }

    @Test("UTF-8 text and non-destructive finalize")
    func utf8AndFinalize() {
        #expect(SHA256.hexDigest(of: "café") == "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e")
        #expect(SHA256.hexDigest(of: Data("Hello, Lumen!\n".utf8)) == "3564906fe6ba67e3e227f79eafa0f8401263a1b2c2c9cbcafc0f0e39e3e882bc")

        var hasher = SHA256()
        hasher.update(Array("ab".utf8))
        _ = hasher.finalize()
        hasher.update(Array("c".utf8))
        #expect(hasher.finalizeHex() == SHA256.hexDigest(of: "abc"))
        #expect(SHA256.hash(Data()).count == SHA256.digestByteCount)
    }
}
