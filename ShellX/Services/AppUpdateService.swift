import AppKit
import Combine
import Foundation

struct AppUpdateRelease: Identifiable, Equatable {
    let id: Int
    let version: String
    let tagName: String
    let name: String
    let htmlURL: URL
    let asset: AppUpdateAsset
}

struct AppUpdateAsset: Equatable {
    let name: String
    let downloadURL: URL
    let size: Int
}

enum AppUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(AppUpdateRelease)
    case downloading(AppUpdateRelease, progress: Double)
    case readyToRestart(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "尚未检查更新"
        case .checking:
            return "正在检查 GitHub Release..."
        case .upToDate(let version):
            return "当前已是最新版本：\(version)"
        case .updateAvailable(let release):
            return "发现新版本：\(release.tagName)"
        case .downloading(let release, let progress):
            return "正在下载 \(release.tagName)：\(Int(progress * 100))%"
        case .readyToRestart(let release):
            return "\(release.tagName) 已下载，重启 ShellX 后安装并生效"
        case .installing(let release):
            return "正在安装 \(release.tagName)，ShellX 将重新打开"
        case .failed(let message):
            return message
        }
    }

    var downloadProgress: Double? {
        if case .downloading(_, let progress) = self {
            return progress
        }
        return nil
    }
}

@MainActor
final class AppUpdateService: NSObject, ObservableObject {
    private enum Constants {
        static let appName = "ShellX"
        static let releasesURL = URL(string: "https://api.github.com/repos/dylan120/shellx/releases/latest")!
    }

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var lastCheckedAt: Date?

    private var activeRelease: AppUpdateRelease?
    private var activeAsset: AppUpdateAsset?
    private var pendingInstallAssetURL: URL?
    private lazy var downloadSession = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    func checkForUpdates(automaticallyInstalls: Bool = false) {
        guard !isBusy else { return }
        phase = .checking

        Task {
            do {
                let release = try await fetchLatestRelease()
                lastCheckedAt = Date()

                guard Self.compareVersions(release.version, currentVersion) == .orderedDescending else {
                    phase = .upToDate(version: currentVersion)
                    return
                }

                phase = .updateAvailable(release)
                if automaticallyInstalls {
                    beginDownloadAndInstall(release)
                }
            } catch {
                phase = .failed("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    func downloadAndInstallAvailableUpdate() {
        guard case .updateAvailable(let release) = phase else { return }
        beginDownloadAndInstall(release)
    }

    func restartToApplyDownloadedUpdate() {
        guard case .readyToRestart(let release) = phase,
              let pendingInstallAssetURL else { return }
        do {
            phase = .installing(release)
            try installAndRelaunch(assetURL: pendingInstallAssetURL, release: release)
        } catch {
            phase = .failed("安装更新失败：\(error.localizedDescription)")
        }
    }

    private func beginDownloadAndInstall(_ release: AppUpdateRelease) {
        guard !isBusy || phase == .updateAvailable(release) else { return }
        activeRelease = release
        activeAsset = release.asset
        pendingInstallAssetURL = nil
        phase = .downloading(release, progress: 0)

        var request = URLRequest(url: release.asset.downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("ShellX/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        downloadSession.downloadTask(with: request).resume()
    }

    private func fetchLatestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: Constants.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ShellX/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateError.invalidReleaseResponse
        }

        let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw AppUpdateError.noStableRelease
        }

        guard let asset = release.assets
            .compactMap(Self.supportedAsset)
            .sorted(by: Self.preferredAssetOrder)
            .first else {
            throw AppUpdateError.noSupportedAsset
        }

        return AppUpdateRelease(
            id: release.id,
            version: Self.normalizedVersion(release.tagName),
            tagName: release.tagName,
            name: release.name ?? release.tagName,
            htmlURL: release.htmlURL,
            asset: asset
        )
    }

    private func handleDownloadedFile(at temporaryURL: URL) {
        guard let release = activeRelease, let asset = activeAsset else { return }

        do {
            let updateURL = try persistDownloadedAsset(temporaryURL, asset: asset, release: release)
            pendingInstallAssetURL = updateURL
            phase = .readyToRestart(release)
        } catch {
            phase = .failed("安装更新失败：\(error.localizedDescription)")
        }
    }

    private func persistDownloadedAsset(
        _ temporaryURL: URL,
        asset: AppUpdateAsset,
        release: AppUpdateRelease
    ) throws -> URL {
        let updatesDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(Constants.appName, isDirectory: true)
        .appendingPathComponent("Updates", isDirectory: true)
        .appendingPathComponent(Self.safeFileComponent(release.tagName), isDirectory: true)

        try FileManager.default.createDirectory(
            at: updatesDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = updatesDirectory.appendingPathComponent(Self.safeFileComponent(asset.name))
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func installAndRelaunch(assetURL: URL, release: AppUpdateRelease) throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw AppUpdateError.invalidCurrentBundle
        }
        guard FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            throw AppUpdateError.currentBundleLocationNotWritable
        }

        let scriptURL = try createInstallerScript()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            scriptURL.path,
            bundleURL.path,
            assetURL.path,
            Constants.appName,
            "\(ProcessInfo.processInfo.processIdentifier)"
        ]
        try process.run()

        // 安装脚本会等待当前进程退出后替换 .app 并重新打开。
        NSApp.terminate(nil)
    }

    private func createInstallerScript() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(Constants.appName, isDirectory: true)
        .appendingPathComponent("Updater", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("install-update.sh")
        try Self.installerScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let maxCount = max(left.count, right.count)

        for index in 0..<maxCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func versionComponents(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: ".")
            .map { component in
                let numericPrefix = component.prefix { $0.isNumber }
                return Int(numericPrefix) ?? 0
            }
    }

    private static func normalizedVersion(_ version: String) -> String {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        return normalized
    }

    private static func supportedAsset(from asset: GitHubReleaseAssetResponse) -> AppUpdateAsset? {
        let lowercasedName = asset.name.lowercased()
        guard lowercasedName.hasSuffix(".dmg") || lowercasedName.hasSuffix(".zip") else {
            return nil
        }
        guard let downloadURL = URL(string: asset.browserDownloadURL) else { return nil }
        return AppUpdateAsset(name: asset.name, downloadURL: downloadURL, size: asset.size)
    }

    private static func preferredAssetOrder(_ lhs: AppUpdateAsset, _ rhs: AppUpdateAsset) -> Bool {
        let leftIsDMG = lhs.name.lowercased().hasSuffix(".dmg")
        let rightIsDMG = rhs.name.lowercased().hasSuffix(".dmg")
        if leftIsDMG != rightIsDMG {
            return leftIsDMG
        }
        return lhs.name < rhs.name
    }

    private static func safeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
    }

    private static let installerScript = """
#!/bin/bash
set -euo pipefail

APP_PATH="$1"
ASSET_PATH="$2"
APP_NAME="$3"
APP_PID="$4"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shellx-update.XXXXXX")"
MOUNT_DIR="$WORK_DIR/mount"
EXTRACT_DIR="$WORK_DIR/extract"

cleanup() {
  if mount | grep -q "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

while kill -0 "$APP_PID" >/dev/null 2>&1; do
  sleep 0.2
done

find_app() {
  find "$1" -maxdepth 3 -name "$APP_NAME.app" -type d -print -quit
}

mkdir -p "$MOUNT_DIR" "$EXTRACT_DIR"
case "$ASSET_PATH" in
  *.dmg|*.DMG)
    hdiutil attach "$ASSET_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
    SOURCE_APP="$(find_app "$MOUNT_DIR")"
    ;;
  *.zip|*.ZIP)
    ditto -x -k "$ASSET_PATH" "$EXTRACT_DIR"
    SOURCE_APP="$(find_app "$EXTRACT_DIR")"
    ;;
  *)
    echo "Unsupported update asset: $ASSET_PATH" >&2
    exit 2
    ;;
esac

if [ -z "${SOURCE_APP:-}" ]; then
  echo "Cannot find $APP_NAME.app in update asset." >&2
  exit 3
fi

OLD_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
NEW_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$OLD_BUNDLE_ID" ] && [ "$OLD_BUNDLE_ID" != "$NEW_BUNDLE_ID" ]; then
  echo "Bundle identifier mismatch: $NEW_BUNDLE_ID" >&2
  exit 4
fi

rm -rf "$APP_PATH"
ditto "$SOURCE_APP" "$APP_PATH"

# 未签名构建通过自动更新落盘后，macOS 可能保留下载隔离属性，导致下次启动被 Gatekeeper 拦截。
# GUI 自动更新流程不能交互式输入 sudo 密码，因此这里只执行当前用户权限下可完成的本机修复；失败不阻断安装。
# 不自动执行 xattr -cr，避免清理除隔离标记之外的扩展属性。
/usr/bin/codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
/usr/bin/xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true

open "$APP_PATH"
"""
}

extension AppUpdateService: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        Task { @MainActor [weak self] in
            guard let self, let release = self.activeRelease else { return }
            self.phase = .downloading(release, progress: progress)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            Task { @MainActor [weak self] in
                self?.phase = .failed("下载更新失败：HTTP \(response.statusCode)")
            }
            return
        }

        let retainedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellx-update-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: location, to: retainedURL)
        } catch {
            Task { @MainActor [weak self] in
                self?.phase = .failed("保存更新包失败：\(error.localizedDescription)")
            }
            return
        }

        Task { @MainActor [weak self] in
            self?.handleDownloadedFile(at: retainedURL)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.phase = .failed("下载更新失败：\(error.localizedDescription)")
        }
    }
}

private enum AppUpdateError: LocalizedError {
    case invalidReleaseResponse
    case noStableRelease
    case noSupportedAsset
    case invalidCurrentBundle
    case currentBundleLocationNotWritable

    var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            return "GitHub Release 响应不可用。"
        case .noStableRelease:
            return "未找到稳定版本 Release。"
        case .noSupportedAsset:
            return "最新 Release 未包含 .dmg 或 .zip 安装包。"
        case .invalidCurrentBundle:
            return "当前运行产物不是可替换的 .app。"
        case .currentBundleLocationNotWritable:
            return "当前应用所在目录不可写，请手动安装下载的 Release 安装包。"
        }
    }
}

private struct GitHubReleaseResponse: Decodable {
    let id: Int
    let tagName: String
    let name: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAssetResponse]

    private enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAssetResponse: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
