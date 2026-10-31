# sign-hap.ps1 —— 用 OpenHarmony SDK 自带材料给 HAP 做本地签名（不需要华为账号）
#
# 为什么需要这个脚本
#   `app/build-profile.json5` 的 `signingConfigs` 留空时，hvigor 只产出
#   `entry-default-unsigned.hap` —— 这种包**装不进任何设备**（真机/模拟器都拒装）。
#   DevEco 图形界面里的自动签名要登录华为账号、且只对「已连接的设备」生成调试证书。
#   本脚本走 OpenHarmony 开源侧的本地签名链路，材料全部来自 SDK，可完全离线。
#
# 材料（都在 $SdkRoot\toolchains\lib）
#   OpenHarmony.p12                      官方测试根 + 中间 CA + 应用签名私钥（口令 123456）
#   OpenHarmonyProfileRelease.pem         Profile 签名证书
#   UnsgnedReleasedProfileTemplate.json   Profile 模板（release 型，不绑定设备 UDID）
#   hap-sign-tool.jar                     签名工具
#
# 链路
#   ① 生成 Profile：release 模板 + 本项目 bundle-name，用官方 profile release 私钥签成 p7b
#   ② 组应用证书链：**Profile 里内嵌的 distribution-certificate** → App CA → Root CA
#   ③ sign-app：用 profile 对应的私钥签名 → entry-default-signed.hap
#   ④ verify-app 校验
#
# 踩坑记录（两次失败，别重走）
#   ✗ 用 `keytool -genkeypair` 自建应用密钥、再让 `openharmony application ca` 给它签证书：
#     sign-profile 能过，sign-app 报 `verify certificate chain failed! Signature does not match.`
#     —— hap-sign-tool 要求应用证书链**必须与 Profile 里内嵌的那张证书同源**。
#   ✗ 用 `keytool -exportcert -alias 'openharmony application release'` 导出的证书：
#     那是 p12 里存的**自签副本**，与 Profile 内嵌的 Release 证书不是同一张，
#     于是要么报 chain 校验失败，要么报 `Profile cert ... must a cert chain`。
#   ✓ 正解：从 UnsgnedReleasedProfileTemplate.json 的 `bundle-info.distribution-certificate`
#     取证书，再接 App CA 与 Root CA 组成三级链。
#
# 适用范围
#   签名私钥是 OpenHarmony 公开的**测试密钥**，只适合自测与开源生态演示，
#   不能用于正式商用分发（正式分发需自备证书）。
#
# 用法
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sign-hap.ps1
param(
  [string]$Hap = '',
  [string]$Out = '',
  [string]$SdkRoot = 'C:\Users\Admin\ohos-sdk\12',
  [string]$DevEcoRoot = 'C:\Program Files\Huawei\DevEco Studio',
  [string]$BundleName = 'com.carbonboo.app'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $Hap) { $Hap = Join-Path $repo 'app\entry\build\default\outputs\default\entry-default-unsigned.hap' }
if (-not $Out) { $Out = Join-Path $repo 'app\entry\build\default\outputs\default\entry-default-signed.hap' }
if (-not (Test-Path $Hap)) { throw "找不到待签名的 HAP：$Hap（先跑 assembleHap）" }

$lib     = Join-Path $SdkRoot 'toolchains\lib'
$signJar = Join-Path $lib 'hap-sign-tool.jar'
$ohP12   = Join-Path $lib 'OpenHarmony.p12'
$relPem  = Join-Path $lib 'OpenHarmonyProfileRelease.pem'
$tplJsn  = Join-Path $lib 'UnsgnedReleasedProfileTemplate.json'
foreach ($p in @($signJar, $ohP12, $relPem, $tplJsn)) {
  if (-not (Test-Path $p)) { throw "SDK 里缺少签名材料：$p" }
}

$keytool = Join-Path $DevEcoRoot 'jbr\bin\keytool.exe'
$java    = Join-Path $DevEcoRoot 'jbr\bin\java.exe'
foreach ($p in @($keytool, $java)) { if (-not (Test-Path $p)) { throw "找不到 $p" } }

$work = Join-Path $repo 'sign'
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work | Out-Null }
$profJsn = Join-Path $work 'profile.json'
$profP7b = Join-Path $work 'profile.p7b'
$caCr    = Join-Path $work 'app-ca.cer'
$rootCr  = Join-Path $work 'root-ca.cer'
$chain   = Join-Path $work 'app-chain.cer'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

# ① Profile：release 模板 + 本项目 bundle-name
Step "生成 Profile（bundle-name=$BundleName）"
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$tpl = Get-Content $tplJsn -Raw -Encoding UTF8 | ConvertFrom-Json
$leafPem = $tpl.'bundle-info'.'distribution-certificate'.Replace('\n', "`n")
$tpl.'bundle-info'.'bundle-name' = $BundleName
$tpl.'bundle-info'.'developer-id' = 'CarbonBoo'
$tpl.uuid = [guid]::NewGuid().ToString()
$tpl.validity.'not-before' = $now - 86400
$tpl.validity.'not-after' = $now + 315360000
# 分享卡片「保存到相册」要 WRITE_IMAGEVIDEO，它在 HarmonyOS 上属受限权限，
# 必须在 Profile 的 allowed-acls / restricted-permissions 里显式授予，否则安装报
# `install failed due to grant request permissions failed`。
$tpl.acls.'allowed-acls' = @('ohos.permission.WRITE_IMAGEVIDEO')
$tpl.permissions.'restricted-permissions' = @('ohos.permission.WRITE_IMAGEVIDEO')
$json = $tpl | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($profJsn, $json, [System.Text.UTF8Encoding]::new($false))

& $java -jar $signJar sign-profile -keyAlias 'openharmony application profile release' `
  -signAlg SHA256withECDSA -mode localSign -profileCertFile $relPem `
  -inFile $profJsn -keystoreFile $ohP12 -outFile $profP7b `
  -keyPwd 123456 -keystorePwd 123456
if ($LASTEXITCODE -ne 0) { throw "sign-profile 失败（$LASTEXITCODE）" }
Step "Profile 已签出 → sign\profile.p7b（$((Get-Item $profP7b).Length) B）"

# ② 应用证书链 = Profile 内嵌证书 + App CA + Root CA
Step '导出 App CA 与 Root CA'
& $keytool -exportcert -alias 'openharmony application ca' -keystore $ohP12 -storetype PKCS12 `
  -storepass 123456 -rfc -file $caCr
if ($LASTEXITCODE -ne 0) { throw "导出 App CA 失败（$LASTEXITCODE）" }
& $keytool -exportcert -alias 'openharmony application root ca' -keystore $ohP12 -storetype PKCS12 `
  -storepass 123456 -rfc -file $rootCr
if ($LASTEXITCODE -ne 0) { throw "导出 Root CA 失败（$LASTEXITCODE）" }

$txt = $leafPem + (Get-Content $caCr -Raw) + (Get-Content $rootCr -Raw)
[System.IO.File]::WriteAllText($chain, $txt, [System.Text.UTF8Encoding]::new($false))
$n = ([regex]::Matches($txt, 'BEGIN CERTIFICATE')).Count
if ($n -ne 3) { throw "应用证书链应为 3 张证书，实际 $n 张" }
Step "应用证书链（3 张）→ sign\app-chain.cer（$((Get-Item $chain).Length) B）"

# ③ 给 HAP 签名
Step "给 HAP 签名 → $Out"
& $java -jar $signJar sign-app -keyAlias 'openharmony application release' `
  -signAlg SHA256withECDSA -mode localSign -appCertFile $chain -profileFile $profP7b `
  -inFile $Hap -outFile $Out -keystoreFile $ohP12 -keyPwd 123456 -keystorePwd 123456 -signCode 1
if ($LASTEXITCODE -ne 0) { throw "sign-app 失败（$LASTEXITCODE）" }

# ④ 校验
Step '校验签名'
& $java -jar $signJar verify-app -inFile $Out `
  -outCertChain (Join-Path $work 'verify-chain.cer') -outProfile (Join-Path $work 'verify-profile.p7b')
if ($LASTEXITCODE -ne 0) { throw "verify-app 失败（$LASTEXITCODE）" }

[pscustomobject]@{
  '未签名 HAP' = $Hap
  '已签名 HAP' = $Out
  '大小(B)'    = (Get-Item $Out).Length
  'BundleName' = $BundleName
  'Profile'    = $profP7b
} | Format-List
Write-Host '签名完成：这个 HAP 可 hdc install 到已开启开发者模式的 OpenHarmony 设备。' -ForegroundColor Green
