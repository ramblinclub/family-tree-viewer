import AuthenticationServices
import Foundation

/// Stores the device's authenticated Apple identity separately from the
/// family-tree person selected as the active account perspective.
///
/// The Apple subject identifier is intentionally kept local for now. A later
/// sync service can use it to authenticate the family workspace without ever
/// uploading the original archive folder.
@MainActor
final class AccountSessionStore: ObservableObject {
    private static let appleUserIDKey = "FamilyArchive.appleUserID"

    @Published private(set) var appleUserID: String?
    @Published var errorMessage: String?

    init() {
        appleUserID = UserDefaults.standard.string(forKey: Self.appleUserIDKey)
    }

    var isSignedIn: Bool {
        appleUserID != nil
    }

    func handleAppleAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple sign-in returned an unsupported credential."
                return
            }

            appleUserID = credential.user
            UserDefaults.standard.set(credential.user, forKey: Self.appleUserIDKey)
            errorMessage = nil
        case .failure(let error):
            // Cancellation is a normal user action, not an account error.
            guard (error as? ASAuthorizationError)?.code != .canceled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        appleUserID = nil
        UserDefaults.standard.removeObject(forKey: Self.appleUserIDKey)
    }
}
