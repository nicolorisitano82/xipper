import CryptoKit
import Foundation
import Testing
@testable import XipperKit

/// XIZ 1.7 (§17): post-quantum recipients and custodians with X-Wing (ML-KEM-768 + X25519).
@Suite("XIZ post-quantum recipients", .serialized)
struct XizPQTests {
    func tree(_ t: TempDir) {
        t.write("src/indice.txt", "indice del caso\n")
        t.write("src/referti/r1.txt", "referto uno\n")
        t.write("src/dati/g.bin", sampleData(300_000, seed: 3))
    }

    func paths(_ a: URL, password: String? = nil) throws -> Set<String> {
        Set(try Xipper.list(a, password: password).filter { $0.kind == .file }.map(\.path))
    }

    @Test func keyTexts() throws {
        let k = XizIdentity(postQuantum: true)
        #expect(k.isPostQuantum && k.publicKey.count == 1216)
        #expect(k.publicText.hasPrefix("xizpq1") && k.secretText.hasPrefix("XIZ-SECRET-KEY-PQ-1-"))
        let back = try XizIdentity(secretText: k.fileText)
        #expect(back.isPostQuantum && back.publicKey == k.publicKey)
        #expect(try XizIdentity.publicKey(fromText: k.publicText) == k.publicKey)
        let classic = XizIdentity()
        #expect(!classic.isPostQuantum && classic.publicText.hasPrefix("xizpk1"))
        #expect(try XizIdentity.publicKey(fromText: classic.publicText).count == 32)
        #expect(throws: XipperError.self) { _ = try XizIdentity.publicKey(fromText: String(k.publicText.dropLast(4))) }
        #expect(throws: XipperError.self) { _ = try XizIdentity.publicKey(fromText: "xizpq1" + Base64URL.encode(classic.publicKey)) }
    }

    /// age's keys are the same keys (C2SP age.md, MLKEM768-X25519 example): the identity's seed gives
    /// CryptoKit exactly the recipient's X-Wing public key.
    @Test func ageKeys() throws {
        let identity = "AGE-SECRET-KEY-PQ-1XX76JRALNLXDMEW0CRK45QMCCH4X06SE84UN3VPM33W6HWDX0H3SK3ZQFR"
        let recipient = [
        "age1pq1x34nzsvr0rxjsgdn8zgyhfe8j7ceq5r9rdelkjuh3y235jzxshfg87pzf5zrqtzdxz95paef6caq5aapdmwjjqpjfdyxn",
        "zr2zampc3uxy0dg4z2n2gm9su72p0pc3u0jvev55l694v78snxg3yzvcl7yda0eyytqj6a0ec477lnhcy5hzpz4zq3pxanve4cn6",
        "2gqj3pjy5lqj9c6kyj4v2z8alktn8zh99970x79gjkv7522hv9kfz35zsnxhsx8wwtmu9cy3ftzjgwcp4sshn3llnylnpdsyz5jm",
        "72vefv4x5vfwytrefxg4wq3mv42wcrvkj742479zrxzpvp2p3e9fed9f0739vcu80r7ma28qfhnvlv4gfzel9q654dj3zmuvvz89",
        "3azhxdvs9fxd0r7jzchzcfcs5mkyyjxhw0n2z6dvp9yn9qfdp29h0azxqyjw6v7fhyuzj7zel0uq6j9rd7wgrpz7mf5dnj43jwsg",
        "vrc8qcnhy7tu6dkdujuxzkp9xj43xe8h92ktre2a3u3s8mm5mrp9nr9pwkgtz4mdlq9hgn4fps4k57ff6wddn2fy23t47sm20r8k",
        "m8sd2pcyyafnet8f0dajsrlyjeah4n3mssr6aseevuuskdvq5lzguyvpgwpta742c6698vgutzqgny8usfg0w2he7kq5vyxjd0f9",
        "hqg8xk26y9e4th0gezq92q4cpp5p2y9hf5f2cje5l0c3sa3a2qxmm38pxxvhxh99yzmfz0zk7r2s64nnwjhkfgfr3gf8xnmppcgm",
        "aykvh5sh6g7vk9790rf8ws0axmr2t7z8aae5fq2029uvcn2ghgt4fu4wgwdc0k0cz52qkvwmuzj8p8k5jgf3xzk5zmrkavjekjrp",
        "eq408xz3zxazwkc6tyfmhayrkfpjhwtz5mp8j8guqe43k2q6m2kte03vrw27y3wmqyu5etmt9dnkwcnnpmu9gz9dekfhdevf42uc",
        "shphnrk38ra6hx8w5f8q5ru0xdhrjxmwqf6cused7zc5xvq43r0zscjglpwlptpwydhqw64xz7ptjdyeyzpq2zkxtmzg29gzjpvz",
        "va4d3l0cenn9xs297wf4y4ukwrunf57xj6pm7nvrkwvtrt8hwcmgv8x7ajw7258ugf9wvkmk4052ekg87tw5vnx8nq2swyzv77v8",
        "yqlwsenvamr0zssknwts8rrhfuwj7ykysnq9jxy0uv3kuyt22djszjdtvpz6d0s0kwh8ryynddzud92emeyvvyqktd0jtj7rvvg5",
        "gch25v8smlvny3kvn5gagyz475ze2y6q466xqmz2n3hs77lddeqyta2nch5k2u5yacuk9ywnwfdzvyejnucz724hj77hrrmakm7p",
        "r3kxsrxq22ejexlud9fy2kdqmkg5yncz7jm5wv2qjk5w5kvcpqsry2yqffh2la52dxfjkjq5rzhjzeyn6dupn0qwtyv7s4lwg3xd",
        "arsdlwe2y3tujy480y7z39q259fzx6jhd2j0f5hagqpcpees7hzc2yrk5cy788uk3s7qvp5cpepx24gvws3m2g433exgwppnkjsc",
        "ec8qu4y9z9r7vccexjcjaen42245lmgmxmuavg9alej92322gvvyy2t6267v09ch64y0m53jff0vjj96s0ypk60hr3jw4myd6m5h",
        "pn3xjstx7tl2szhpr5qe8jj08ydjc4wy2rch2fhuy3pdfjax5awe9j99ly5hkntzz9fe5zatgjvzdd0kgtxs25njnajyf6ssekp7",
        "gelxquusn4pt25czh3scj68kq79wdn5tgm6yvm9nzavrg043x3msnygf8dweknw5jmqd0uvny6ttsn09508k0c55zfnegrm9efhx",
        "pfqdkmhh6gjtqmwze9pyyzk3tlhl53k2ykx3qheyty7saeq0d3fzv49zc0k",
        ].joined()
        let k = try XizIdentity(secretText: "# created by age-keygen\n" + identity + "\n")
        #expect(k.isPostQuantum)
        let pub = try XizIdentity.publicKey(fromText: recipient)
        #expect(pub.count == 1216 && pub == k.publicKey)
        #expect(k.publicText.hasPrefix("xizpq1") && k.secretText.hasPrefix("XIZ-SECRET-KEY-PQ-1-"))
        #expect(try XizIdentity(secretText: identity.lowercased()).publicKey == pub)
        // A damaged checksum, mixed case, or a classic HRP with a PQ payload are refused.
        var bad = Array(recipient)
        bad[bad.count - 3] = bad[bad.count - 3] == "q" ? "p" : "q"
        #expect(throws: XipperError.self) { _ = try XizIdentity.publicKey(fromText: String(bad)) }
        #expect(throws: XipperError.self) { _ = try XizIdentity(secretText: "AGE-SECRET-KEY-PQ-1xX76JRALNLXDMEW0CRK45QMCCH4X06SE84UN3VPM33W6HWDX0H3SK3ZQFR") }
        #expect(throws: XipperError.self) { _ = try XizIdentity(secretText: String(identity.dropLast())) }
        // age's own test data (cmd/age/testdata/hybrid.txt) and the classic X25519 pairs (C2SP age.md
        // and cmd/age/testdata/x25519.txt): X25519 recipients are 32-byte xizpk1 keys.
        let hybrid = try XizIdentity(secretText: "AGE-SECRET-KEY-PQ-16XDSLZ3XCSZ3236YJ5J0T9NAPLZTP96LJKQCVHJYUDTQVJR5J5PQTDPQCX")
        let hybridPub = try XizIdentity.publicKey(fromText: [
            "age1pq1044e3hfmq2tltgck54m0gnpv8rfrwkdxjgl38psnwg8zfyv4uqdu63kk0u94ztt0q35k9dzuwgv405kxq6due2sre2kfs",
            "jftf7k2vz2mdpetku9pufy9d6ny6k5ss0cghpxdxrux0yd5xy40f8fu8ch9xn2rczyek2pqetqk0l9fqj0e3hfhkyfmcf9j6cpe5",
            "mf5stt9cymfq3xm276x4sramhn8srr42g78q9rkmqesevy33p4kdhkuggl99x9zx7j05uflx3s8q558xeaq9q9ctxqx52rzg6yff",
            "wykxngvxf7g3n83ddawagq2lnk59kcnexm54jrsmkjk9nemlge9v6p7fxu5z6yvq3ghpet8ww2c3h9fylvjx6j9njwz744376ap5",
            "r3xcpzh7qlk0kq3gknzfqhmxmjqypf6xz6geffdmy25apzsfr4ce0x825njkf62mgzx0x9n3zt0490u4dnt4468zse4zvd9sv0yc",
            "x2u2wsseuy4yymrg0nmfuxcwq9q0jykq7g5f59vunf95vnmcw336ksrh43fgapsd40u4227ymx56xtudtrte39twnq6fdfdj4p9p",
            "gx7pcqdk953za76fqcnvatx2cmywurag7ky4y8ecq5lvf25rydhxg6gmcn6vf78vtsqw79hp3mzv2u4v4jzn0nk50kl4gpv7k60c",
            "gz79c6k30jzy8dyetqtwg04tguxkv2p4hqj02yvsz2szaqdn9flu24rhth3v0t33023nwy27gt0x32eqpa5tpz6ygz3yzcsa3w88",
            "9drpynzd5hlywuk9dwgafuax7upfnnxch4znrx4vactasg32u7vl886pxfswskk7wjgqkggrewtnaecfusl3nmg0xxh8e5nl5eft",
            "0xqwj5rk9ajn2j6yxehhgg5k6kpw5pk382hxmpu8wcd3rqx6m8905c7f8v0x2z9gyduxtqp2fdy9w2z4g2rrgu4d5cqes5tnwag0",
            "07h2f326s3j9p6970xyd73rv5awx27zzezrax467c6vuye62ha88pzhw9xytjpezw3vg3l6x4k9rxwm9f6lwj6j7r9makg59rhgt",
            "0355s3jx9vw3raz5qdk5cnpny56q5h3dyd75suskuz63wmmfp9333tx4ry38vnh7jxy0j0cka99y7v2dmyjldjy0mqjetcefsmmg",
            "3pw0h9ll0rtskpmxz2cs8vmx6lu4v5rjtzpzgaqt46cwvnmhy5e3ye0tv6sre342lwg0tfd0yjkfz2haqc3hprpqf5ce8c9lx076",
            "dnk5cukn3tu38jgprrxt9sk9nqzt8grvkc4qzlg8jjf638v07ej9cf4eu48kphrgyjy83qm822xq8v9k22zwa7txr439x74j2f9a",
            "y7frkwtfdwn02enyx8stjpr4wgg25n5tj7uxyx0dqt3hnrqf7dcgt9fqnkjgemjfzyck6pawewptcayxm49sq3477f4cvm2p8fmg",
            "27rcmwm5l2vmzvdmymvkrr3aywu04y3zlhs7awu3r9u9lseheqpffvm2xf8y6w2qaj9g22pcu0sdsnqseusrxq9awru5lyqxnzft",
            "lslgpe3njegxkze98rveswp3u0xgx69wkg38vgp4k55lwwgv5l7ccv503mh9q23nud4xtm499xq276u40rxyrzaqfyuz2f3v5qr2",
            "vq00xs4g3ruynmq0c6nprvjcwqc5zrdn4cnzeeuwumjvqfjdpxr739n4cqcwytc8pjmfcj2qs3l2a8p5fzq7nvtng2jvvklx0x5y",
            "pnlkeuegsm587f6d4dkwel2es0lwwt88y2jdg8enjyph02tnjyndlx34h52fngjk96ggtu6vcxqkreqcxs4gwa8ww40t0kzlxfzy",
            "fhtjmfdm5fcrr5pt2xm4yslfynr0h9wkranhyadxf33kjn9xpg2fq5hnlq0",
        ].joined())
        #expect(hybrid.publicKey == hybridPub)
        for (id, rcpt) in [("AGE-SECRET-KEY-1GFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPYYSJZGFPQ4EGAEX",
                            "age1zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj"),
                           ("AGE-SECRET-KEY-1EGTZVFFV20835NWYV6270LXYVK2VKNX2MMDKWYKLMGR48UAWX40Q2P2LM0",
                            "age1xmwwc06ly3ee5rytxm9mflaz2u56jjj36s0mypdrwsvlul66mv4q47ryef")] {
            let c = try XizIdentity(secretText: id)
            let pub = try XizIdentity.publicKey(fromText: rcpt)
            #expect(!c.isPostQuantum && c.publicKey == pub)
            #expect(c.publicText.hasPrefix("xizpk1"))
        }
        // An X25519 payload under the post-quantum HRP is refused (wrong size).
        #expect(throws: XipperError.self) { _ = try XizIdentity.publicKey(fromText: "age1pq1" + "zvkyg2lqzraa2lnjvqej32nkuu0ues2s82hzrye869xeexvn73equnujwj") }
    }

    @Test func recipientsAndCustodians() throws {
        sharedCredentialsLock.lock()
        defer { sharedCredentialsLock.unlock() }
        XizCredentials.shared.removeAll()
        defer { XizCredentials.shared.removeAll() }
        let t = TempDir()
        tree(t)
        let lab = XizIdentity(postQuantum: true), dpo = XizIdentity(postQuantum: true), it = XizIdentity(postQuantum: true)
        let classic = XizIdentity()
        var o = CreateOptions()
        o.format = .xiz
        o.xizKDF = .minimum
        o.xizAccess = XizAccess(
            groups: [.init(name: "referti", prefixes: ["src/referti"]), .init(name: "dati", prefixes: ["src/dati"])],
            recipients: [.init(label: "Laboratorio", credential: .publicKey(lab.publicKey)),
                         .init(label: "Ricerca", credential: .publicKey(classic.publicKey), groups: [""])],
            thresholds: [.init(label: "Dati", k: 2, custodians: [
                .init(label: "DPO", credential: .publicKey(dpo.publicKey)), .init(label: "IT", credential: .publicKey(it.publicKey)),
                .init(label: "Direttore", credential: .password("dir"))], groups: ["dati"])])
        let a = t.url("pq.xiz")
        try Xipper.create(from: [t.url("src")], to: a, options: o)
        let sb = try Xiz.Superblock.decode(try FileReader(path: a.path).read(at: 0, count: 64))
        #expect(sb.minor == 7 && sb.required == [.encrypted, .directory])

        let all: Set = ["src/indice.txt", "src/referti/r1.txt", "src/dati/g.bin"]
        XizCredentials.shared.add(identity: lab)
        #expect(try paths(a) == all)
        #expect(try Xipper.test(a).isOK)
        t.mkdir("out")
        try Xipper.extract(a, to: t.url("out"), mode: .into, options: ExtractOptions())
        #expect(treesEqual(t.path + "/src", t.path + "/out/src").0)
        XizCredentials.shared.removeAll()

        // The X25519 recipient next to the X-Wing ones: its group only.
        XizCredentials.shared.add(identity: classic)
        #expect(try paths(a) == ["src/indice.txt"])
        XizCredentials.shared.removeAll()

        // Two post-quantum custodians, or one with the password custodian.
        XizCredentials.shared.add(identity: dpo)
        #expect(throws: XipperError.self) { _ = try Xipper.list(a) }
        XizCredentials.shared.add(identity: it)
        #expect(try paths(a) == ["src/dati/g.bin"])
        XizCredentials.shared.removeAll()
        XizCredentials.shared.add(identity: it)
        #expect(try paths(a, password: "dir") == ["src/dati/g.bin"])
        XizCredentials.shared.removeAll()

        // Another X-Wing key, even with a matching-looking archive, opens nothing.
        XizCredentials.shared.add(identity: XizIdentity(postQuantum: true))
        #expect(throws: XipperError.self) { _ = try Xipper.list(a) }
        XizCredentials.shared.removeAll()

        // Public description: labels and key ids, without any key.
        let info = try Xipper.xizInfo(a)
        #expect(info.recipients.map(\.label) == ["Laboratorio", "Ricerca", "Dati", "DPO", "IT", "Direttore"])
        #expect(info.matches(publicKeys: [lab.publicText]) && info.matches(publicKeys: [it.publicText]))
        #expect(!info.matches(publicKeys: [XizIdentity(postQuantum: true).publicText]))

        // Appending keeps 1.7 and the keys block.
        XizCredentials.shared.add(identity: lab)
        t.write("extra/r2.txt", "referto due\n")
        try Xipper.edit(a, changes: [.add(t.url("extra/r2.txt"), as: "src/referti/r2.txt")])
        #expect(try paths(a).contains("src/referti/r2.txt"))
        #expect(try Xipper.test(a).isOK)
    }

    /// A ciphertext changed in the keys block: the block's CRC, then AES-GCM over the header.
    @Test func alteredStanzasDoNotOpen() throws {
        sharedCredentialsLock.lock()
        defer { sharedCredentialsLock.unlock() }
        XizCredentials.shared.removeAll()
        defer { XizCredentials.shared.removeAll() }
        let t = TempDir()
        tree(t)
        let lab = XizIdentity(postQuantum: true)
        var o = CreateOptions()
        o.format = .xiz
        o.xizAccess = XizAccess(recipients: [.init(label: "Lab", credential: .publicKey(lab.publicKey))])
        try Xipper.create(from: [t.url("src")], to: t.url("a.xiz"), options: o)
        let superblock = try FileReader(path: t.path + "/a.xiz").read(at: 0, count: 64)
        let keys = try FileReader(path: t.path + "/a.xiz").read(at: 64, count: Int(try Xiz.Superblock.decode(superblock).keysLength))
        #expect(try XizAccessKeys.open(keys, superblock: superblock, passwords: [], identities: [lab]).groupKeys.count == 1)
        for at in [4 + 2 + 3 + 10, 4 + 2 + 3 + 1119, 4 + 2 + 3 + 1125] {  // ciphertext, its last byte, key id
            var b = keys
            b[at] ^= 0x40
            let crc = Xiz.crc32c(Array(b[..<(b.count - 4)]))
            withUnsafeBytes(of: crc.littleEndian) { b.replaceSubrange((b.count - 4)..., with: $0) }
            #expect(try XizAccessKeys.open(b, superblock: superblock, passwords: [], identities: [lab]).groupKeys.isEmpty)
        }
    }
}
