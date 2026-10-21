# fastlane

fastlane の設定ファイル。iOS アプリの TestFlight 自動デプロイに使用。

## レーン

- `beta`: TestFlight へビルドをアップロード
- `get_build_number`: 最新の TestFlight ビルド番号を取得

## 使い方

### 前提条件

1. Ruby 3.2+
2. fastlane (`gem install fastlane`)
3. XcodeGen (`brew install xcodegen`)
4. App Store Connect API Key
5. コード署名（match または manual）

### ローカル実行

```bash
# 環境変数を設定
export ASC_KEY_ID="your-key-id"
export ASC_ISSUER_ID="your-issuer-id"
export ASC_KEY_CONTENT="$(cat AuthKey_XXX.p8 | base64)"
export APPLE_TEAM_ID="your-team-id"

# match を使う場合
export MATCH_GIT_URL="git@github.com:your-org/certificates.git"
export MATCH_PASSWORD="your-match-password"

# または manual 署名を使う場合
export SIGNING_CERTIFICATE_P12_BASE64="$(cat certificate.p12 | base64)"
export SIGNING_CERTIFICATE_PASSWORD="your-cert-password"
export PROVISIONING_PROFILE_BASE64="$(cat profile.mobileprovision | base64)"

# TestFlight へアップロード
fastlane beta
```

## GitHub Actions

`.github/workflows/deploy-ios.yml` で自動デプロイが設定されています。
main ブランチへの meigicho/ 配下の変更マージ時に自動実行されます。

必要な GitHub Secrets については、PR の説明を参照してください。
