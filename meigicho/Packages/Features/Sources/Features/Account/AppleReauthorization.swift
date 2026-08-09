import AuthenticationServices

#if canImport(UIKit)
import UIKit
#endif

/// アカウント削除時の Apple 再認可（`docs/plans/account-deletion/plan.md` §5.3）。
///
/// `SignInView` の `SignInWithAppleButton` はサインイン（`nonce` + `identityToken`）のためのものだが、
/// ここで欲しいのは削除確認ボタン押下の**直後**に取得する `authorizationCode`（BE のトークン失効用）だけなので、
/// `ASAuthorizationController` を直接使う imperative なラッパーとして実装する。
/// **失効はベストエフォート**（同 plan）— キャンセル以外の失敗も呼び出し側は `nil` として扱い、削除自体は続行してよい。
@MainActor
final class AppleReauthorizationCoordinator: NSObject {
    enum Outcome: Equatable {
        /// UTF-8 化した `authorizationCode`
        case authorizationCode(String)
        /// ユーザーがシステムシートをキャンセルした。**エラーではない**
        case cancelled
        /// 上記以外の失敗。呼び出し側はベストエフォートとして `nil` を送ってよい
        case failed
    }

    /// `ASAuthorizationController` の delegate が一度も呼ばれない場合（review.md 中-R1）に備えたタイムアウト。
    /// これが無いと `continuation` が永久に再開されず、呼び出し側の `isReauthorizing` が固定されたままになる。
    private static let timeoutNanoseconds: UInt64 = 60_000_000_000

    private var continuation: CheckedContinuation<Outcome, Never>?
    /// `ASAuthorizationController.delegate` / `presentationContextProvider` は **weak**。
    /// `performRequests()` 後に controller と self が ARC で解放されると delegate が呼ばれず
    /// `continuation` が永久に再開されない。**resume するまで両方を強参照で保持する**。
    private var controller: ASAuthorizationController?
    private var selfRetain: AppleReauthorizationCoordinator?
    /// タイムアウト監視タスク。`resume(_:)` で必ずキャンセルする（二重 resume を避けるため resume 経路は 1 箇所に集約）。
    private var timeoutTask: Task<Void, Never>?

    /// 現在の Apple ID の再認可を要求する。**サインインさせるのではなく `authorizationCode` を得るためだけ**。
    ///
    /// 進行中に再入した場合は新しい要求を `.failed` で返す（システムシートを二重に出さない）。
    func requestAuthorizationCode() async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            guard self.continuation == nil else {
                continuation.resume(returning: .failed)
                return
            }
            self.continuation = continuation
            self.selfRetain = self

            let request = ASAuthorizationAppleIDProvider().createRequest()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()

            // delegate が一度も呼ばれないまま応答が来ない事態に備える（review.md 中-R1）。
            // resume は `resume(_:)` に集約しているので、delegate コールバックと競合しても二重 resume にはならない。
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.resume(.failed)
            }
        }
    }

    private func resume(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        self.controller = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        // 自己参照を外す前にローカルへ退避する（ここで最後の強参照が消えると self が解放される）
        let retained = selfRetain
        selfRetain = nil
        withExtendedLifetime(retained) {
            continuation.resume(returning: outcome)
        }
    }
}

extension AppleReauthorizationCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        MainActor.assumeIsolated {
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let codeData = credential.authorizationCode,
                let code = String(data: codeData, encoding: .utf8)
            else {
                resume(.failed)
                return
            }
            resume(.authorizationCode(code))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            // ユーザーキャンセルはエラーにしない（`SignInView.handleAppleResult` と同じ判定 — plan §5.3）
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                resume(.cancelled)
            } else {
                resume(.failed)
            }
        }
    }
}

extension AppleReauthorizationCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
            #else
            return ASPresentationAnchor()
            #endif
        }
    }
}
