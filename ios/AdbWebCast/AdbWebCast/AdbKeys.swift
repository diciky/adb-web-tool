import Foundation
import Security

// 内置 ADB RSA 密钥对（PKCS#1 私钥 DER + ADB 格式公钥 blob）。
// 首次连接电视时用它完成 AUTH 握手：电视上勾选「始终允许」后，后续即可免密连接。
// 该密钥只用于 ADB 设备鉴权，不涉及任何服务器/证书。
let ADB_PRIV_DER_B64 =
    "MIIEowIBAAKCAQEAmLGjXzJ11wBrsi0IcQ5MBsTltcvMQXCfd9v6Hb1jn6cJjC4Y7pUzs98yqXIOGNAqhznWVoePiBQ4+MPna32s" +
    "gSyCnAzYQ2MESZDwJVkxHobbVktypTo85veTw/VAQPDTudIvIfhZgqJvzONtDBbkpDCIXopV+H46Yd545LQ2gdz9fdT++EP77r4S" +
    "b0MhQV8fq76jH2DvUkJ0C/mtISnf5QjiwSbPruS+TfDuCoWd4ZUypwzCg5AY3W7mfBzgP9alBbRlYYWM7ITVyDN1ncvFhYldQCSO" +
    "5j94OhEaskX4wpeY2DZBWPusW6TOITePRoQ6I5GtmHxERflxQJ5IxkyMbQIDAQABAoIBADGyTyvirnvFhUe+ZGr3bkMdvm3G4LnD" +
    "wAMws10OkOgbY34eWrr8EJHQaRrBJllpFw5gAqSzBkIR4uEEUcOoaYa5R+EmRRTZm0GeTKq7NsNqvOR/NdcU91Fs7sjuf3UjbKWk" +
    "BPcXb3qXB7A1rP4sTUorCZdLiuOPoczMragyBzOIilRVTm0te6xoLWYTNsZVBcpOF6agDzdTzl1XCNqdOeO4krdufdT/02ACHDG0" +
    "ntv/SHFYQIvd0wZIFserC2+umBfiOIciEkCQAfmzmlA66ZwDHAHVVhGqBScJE4mcshH4pnjJllb+7k9OHpcBGg0RiZ7jtxfm04cK" +
    "2YkAQwhuarkCgYEA1ix58K++F+pKVImXpZk78BfTQSjEiiKy9uQoWInJ6Bu0CMa0nwavVIpZw1NSTO73FQAGMgcMDbJDxZIkhKF5" +
    "vjiysPYkxSv06R6CaSExGFlWExK2xH96fNV7e1mqSro1usc0cekdxZbdyBo8Xua7IFGl5Bp2uUaRe24i8+q0mgsCgYEAtoOA/yGQ" +
    "5fBjA3T9KFhgGxxVjUHqBnluiRJXb+NGFfjIBCcgZOU0zv1l0A5AlWAAQwrx5gKk8SvZ6UCNxJovlc5xb/HKt1mbZE0Q8Y5457Tq" +
    "xjGKmKdWpqWhwu94Cb453zOMOfVojjEmMx3oksmZWWB2mdlz8WxaxnbvE8BU9mcCgYBmsWzGu32qeeyqHE9aV98lgEcLN0EF+x1U" +
    "xJGT4n2tjZsFmkGA/vOS1cO0pH8R5IMUzq4pzrc42gEk+q4H6mU1kHod3+hBopIMNVTSk9e2lR9whcic74ML2FEdFCFTM3YP2PSM" +
    "qfpcg7pT+EB6QKf5Fy0z8nx62htn06duzVtLgQKBgQCEzlvnSj1tk+X4dgBggy4rjAqUpwnrfCD6jOYi/HXbNxQUMYRY5o/urmSP" +
    "aE+GYjzOjABJJlNvSkFegSKnlKpbj8TreD3R/NoduhZCLzG7KOJNJW98dQeQa6Wxex8Vt93UlGXNJs3V6d2qBHFfnmJ/rrmeaaT8" +
    "X6QOFi0RajposQKBgA+jicUr016Vv1RvMqeN/0wpuO/6i/clPJiIsHUcevFmn8DbwbFQOIpf/9KHFGr59h+q18Yb+M9serWukaj0" +
    "rCvHpNiQuZeAOQs28s/mCCXBAZ+uLNWxMaXIx2qjv4o2jxF1Vfwgg0xqCQRG/FlnzpnmvmpDEIC0EEd5T7lP85MI"

let ADB_PUB_B64 =
    "QAAAAJuismdtjEzGSJ5AcflFRHyYrZEjOoRGjzchzqRbrPtYQTbYmJfC+EWyGhE6eD/mjiRAXYmFxcuddTPI1YTsjIVhZbQFpdY/" +
    "4Bx85m7dGJCDwgynMpXhnYUK7vBNvuSuzybB4gjl3ykhrfkLdEJS72Afo76rH19BIUNvEr7u+0P4/tR9/dyBNrTkeN5hOn74VYpe" +
    "iDCk5BYMbePMb6KCWfghL9K50/BAQPXDk/fmPDqlcktW24YeMVkl8JBJBGND2AycgiyBrH1r58P4OBSIj4dW1jmHKtAYDnKpMt+z" +
    "M5XuGC6MCaefY70d+tt3n3BBzMu15cQGTA5xCC2yawDXdTJfo7GY354N+azDqlzMhPkxvkQM4amS23N7VpmtLge4mfEHfFIVAw/M" +
    "WO0eEusTxfB0MVlZpnzald1R63X5m6Ld1lEEpKvyozVi7AX38S9IBnlGwvinq3pmav2sEBACQ9Feid+bQM/avJOwM+vVyrDVkuC0" +
    "bdWdkkWlNrgedfkKn+vJWcXqDTZ2h2q6HewL3FEYMxSh1K+i/ObrSa4oI7Ybfb1XJklDg7eBwF9j7rDm4Y3blBBc5hCsY6+Poi87" +
    "HV5r4UVgeAL3qocapUsmtYKaZn+6XOarGfvBy6havTjFjs9SjdjCXJsGjKahJ0J9/NJ7SxsZxPIxD817BtKtvZxz+y0zLQEAAQA="

enum AdbKeys {
    /// 从内置 DER 导入私钥；用于 AUTH type=2 对 20 字节 token 做 RSA-SHA1 PKCS#1 v1.5 签名。
    static var privateKey: SecKey? {
        guard let der = Data(base64Encoded: ADB_PRIV_DER_B64) else { return nil }
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error)
    }

    /// ADB AUTH type=3 的 publickey payload。
    /// 协议要求 payload 是「base64(RSAPublicKey struct) 文本 + '\0'」——与 adb 官方
    /// send_auth_publickey 完全一致（注释仅存在于 adb_keys 文件格式，发送时不带）。
    /// 之前发的是解码后的裸 struct：adbd 按 C 字符串处理，第 2 个字节 0x00 直接截断成
    /// 空串（电视弹框指纹为 MD5("") 的 d41d8cd9…，勾选「一律允许」也存不进去，每次重弹）。
    static var publicBlob: Data? {
        var payload = Data(ADB_PUB_B64.utf8)   // base64 文本本身即 payload 主体
        payload.append(0)                      // '\0' 终止（adbd 按 C 字符串读取，正好保留 base64 部分）
        return payload
    }
}
