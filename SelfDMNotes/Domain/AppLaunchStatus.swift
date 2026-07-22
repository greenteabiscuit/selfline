enum AppLaunchStatus: Equatable {
    case ready
    case unavailable(String)

    var errorMessage: String? {
        guard case let .unavailable(message) = self else {
            return nil
        }
        return message
    }
}
