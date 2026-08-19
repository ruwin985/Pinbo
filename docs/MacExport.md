# macOS 导出与 Apple 公证

macOS 导出脚本位于 `scripts/export_mac.sh`，用于生成支持 Apple 公证的 Developer ID 分发包。

## 前置条件

1. 已安装 Xcode，并通过 `xcode-select` 指向当前 Xcode。
2. 钥匙串中已安装 `Developer ID Application` 证书。
3. `DEVELOPMENT_TEAM` 或 `TEAM_ID` 使用你的 Apple Developer Team ID。
4. 项目已开启 Hardened Runtime；当前 `PinboMac` target 已配置 `ENABLE_HARDENED_RUNTIME: YES`。
5. 如需公证，先获取 Apple ID 和 App 专用密码，并保存 notarytool 凭据。

## 获取 Apple ID 和 App 专用密码

`notarytool` 公证需要 Apple 账号凭据：

- `apple-id`：能访问团队 `KL7QTYJY8K` 的 Apple Developer / App Store Connect 登录邮箱。
- `password`：Apple 账号生成的 App 专用密码，不是 Apple ID 登录密码。

获取方式：

1. 打开 [Apple Developer](https://developer.apple.com/account/) 或 [App Store Connect](https://appstoreconnect.apple.com/)。
2. 使用能访问团队 `KL7QTYJY8K` 的 Apple 账号登录。
3. 登录邮箱就是 `--apple-id`。
4. 打开 [account.apple.com](https://account.apple.com/)。
5. 进入 `登录与安全性` / `Sign-In and Security`。
6. 找到 `App 专用密码` / `App-Specific Passwords`。
7. 新建一个密码，名称可以填写 `pinbo-notary`。
8. 复制生成的密码，格式通常类似 `xxxx-xxxx-xxxx-xxxx`，该密码只显示一次。

如果看不到 App 专用密码，请先确认 Apple 账号已开启双重认证。

## 保存公证凭据

将 `your-apple-id@example.com` 替换为 Apple ID 登录邮箱，将 `app-specific-password` 替换为刚生成的 App 专用密码：

```bash
xcrun notarytool store-credentials pinbo-notary \
  --apple-id your-apple-id@example.com \
  --team-id KL7QTYJY8K \
  --password app-specific-password
```

`app-specific-password` 需要在 Apple ID 账号中创建，不是 Apple ID 登录密码。

保存后可以验证：

```bash
xcrun notarytool history --keychain-profile pinbo-notary
```

如果不再报 `No Keychain password item found`，表示凭据已保存成功。

## 导出并公证

```bash
DEVELOPMENT_TEAM='KL7QTYJY8K' \
NOTARY_PROFILE=pinbo-notary \
VERSION=1.0.0 \
BUILD_NUMBER=1 \
bash scripts/export_mac.sh
```

脚本会依次执行：

1. `xcodegen generate`，如果本机安装了 XcodeGen。
2. `xcodebuild archive`，使用 Developer ID Application 签名，并默认构建 `arm64 x86_64` universal app。
3. 从 `.xcarchive/Products` 复制已签名 `.app`。
4. 校验 `.app` 签名和 `arm64 x86_64` universal 架构。
5. 使用 `hdiutil` 生成 `.dmg`。
6. 对 `.dmg` 签名。
7. 使用 `xcrun notarytool submit --wait` 提交 Apple 公证。
8. 使用 `xcrun stapler staple` 写入公证票据。
9. 使用 `spctl` 做 Gatekeeper 校验。

默认输出目录：

```text
build/mac-export/
```

默认 DMG 文件名包含版本、构建号和架构标识，例如：

```text
Pinbo-1.0.0-1-universal.dmg
```

## 只导出不公证

本地调试可跳过公证：

```bash
DEVELOPMENT_TEAM='KL7QTYJY8K' NOTARIZE=0 bash scripts/export_mac.sh
```

## 常用环境变量

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID，等价于 `TEAM_ID` | 必填 |
| `TEAM_ID` | Apple Developer Team ID | 空 |
| `NOTARY_PROFILE` | notarytool 钥匙串凭据名，等价于 `NOTARY_KEYCHAIN_PROFILE` | 空 |
| `NOTARY_KEYCHAIN_PROFILE` | notarytool 钥匙串凭据名 | 空 |
| `VERSION` | 覆盖 `MARKETING_VERSION` | 工程配置 |
| `BUILD_NUMBER` | 覆盖 `CURRENT_PROJECT_VERSION` | 工程配置 |
| `ARCHS` | macOS app 架构 | `arm64 x86_64` |
| `DMG_ARCH_LABEL` | DMG 文件名里的架构标识 | `universal` |
| `APPLE_ID` | Apple ID，未使用 keychain profile 时需要 | 空 |
| `APPLE_PASSWORD` | Apple ID app-specific password | 空 |
| `SIGNING_IDENTITY` | 签名证书 | `Developer ID Application` |
| `NOTARIZE` | 是否公证，`0` 表示跳过 | `1` |
| `EXPORT_DIR` | 导出目录 | `build/mac-export` |
| `SCHEME` | Xcode scheme | `PinboMac` |
| `CONFIGURATION` | 构建配置 | `Release` |
| `PRODUCT_NAME` | 产品名 | `Pinbo` |

如果钥匙串中有多个 Developer ID Application 证书，建议传入完整证书名：

```bash
DEVELOPMENT_TEAM=ABCDE12345 \
SIGNING_IDENTITY="Developer ID Application: Your Company (ABCDE12345)" \
NOTARY_PROFILE=pinbo-notary \
bash scripts/export_mac.sh
```

## 直接按指定版本导出 Universal DMG

```bash
DEVELOPMENT_TEAM='KL7QTYJY8K' \
NOTARY_PROFILE=pinbo-notary \
VERSION=1.0.0 \
BUILD_NUMBER=1 \
bash scripts/export_mac.sh
```

该命令会生成同时支持 Apple Silicon 和 Intel 的 universal DMG。

## 常见错误

### No Keychain password item found for profile

如果公证时报错：

```text
Error: No Keychain password item found for profile: pinbo-notary
```

说明当前 Mac 的钥匙串里还没有保存名为 `pinbo-notary` 的 notarytool 凭据，先执行：

```bash
xcrun notarytool store-credentials pinbo-notary \
  --apple-id your-apple-id@example.com \
  --team-id KL7QTYJY8K \
  --password app-specific-password
```

保存成功后再执行导出命令：

```bash
DEVELOPMENT_TEAM='KL7QTYJY8K' \
NOTARY_PROFILE=pinbo-notary \
VERSION=1.0.0 \
BUILD_NUMBER=1 \
bash scripts/export_mac.sh
```

如果只是本地验证打包流程，可以先跳过公证：

```bash
DEVELOPMENT_TEAM='KL7QTYJY8K' \
VERSION=1.0.0 \
BUILD_NUMBER=1 \
NOTARIZE=0 \
bash scripts/export_mac.sh
```
